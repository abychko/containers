#!/usr/bin/env bash
#
# ENV variables:
# MYSQL_USER
# MYSQL_PASSWORD
# MYSQL_DATABASE
# MYSQL_ALLOW_EMPTY_PASSWORD
# MYSQL_INITDB_TZINFO
# MYSQL_INITDB_SKIP_TZINFO
# MYSQL_ROOT_HOST
# MYSQL_ROOT_PASSWORD
# PRODUCT
# WSREP_JOIN - a list of node addresses to join in a cluster
#
set -euo pipefail
#
[[ ${IMAGEDEBUG:-0} -eq 1 ]] && set -x
#
PRODUCT="mysql-wsrep"
INITDBDIR="/codership-initdb.d"
# Allowed values are <user-defined password>, RANDOM, EMPTY
MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD:-RANDOM}
[[ ${MYSQL_ALLOW_EMPTY_PASSWORD:-0} -eq 1 ]] && MYSQL_ROOT_PASSWORD="EMPTY"
#
MYSQL_INITDB_TZINFO=${MYSQL_INITDB_TZINFO:-1}
#
MYSQL_DB=mysql
MYSQL_SYSUSER=mysql
#
MYSQL_CLIENT=mysql
MYSQL_SERVER=mysqld
MYSQL_INSTALL_DB=mysql_install_db
MYSQL_TZINFOTOSQL=mysql_tzinfo_to_sql
#
# if command starts with an option, prepend mysqld
if [[ "${1:0:1}" = '-' ]] || [[ -z "${1:0:1}" ]]; then
  set -- ${MYSQL_SERVER} "${@}"
fi
#
message() {
  echo "[Init message]: ${@}"
}
#
error() {
  echo >&2 "[Init ERROR]: ${@}"
}
#
warning() {
  echo >&2 "[Init WARNING]: ${@}"
}
#
debug_exit() {
  rcode=$1
  echo "Failure detected. Some diagnostic info below:"
  echo "id:"
  id
  echo
  echo "ls -l ${DATADIR}:"
  ls -l ${DATADIR} || :
  echo
  echo "tail -n1024 ${LOG_ERROR}"
  tail -n1024 ${LOG_ERROR} || :
  echo
  echo "journalctl -xe --no-pager"
  journalctl -xe --no-pager
  exit $rcode
}
#
# usage: file_env VAR [DEFAULT]
#    ie: file_env 'XYZ_DB_PASSWORD' 'example'
# (will allow for "$XYZ_DB_PASSWORD_FILE" to fill in the value of
#  "$XYZ_DB_PASSWORD" from a file, especially for Docker's secrets feature)
file_env() {
  local var="$1"
  local fileVar="${var}_FILE"
  local def="${2:-}"
  if [ "${!var:-}" ] && [ "${!fileVar:-}" ]; then
    mysql_error "Both $var and $fileVar are set (but are exclusive)"
  fi
  local val="$def"
  if [ "${!var:-}" ]; then
    val="${!var}"
  elif [ "${!fileVar:-}" ]; then
    val="$(< "${!fileVar}")"
  fi
  export "$var"="$val"
  unset "$fileVar"
}
#
validate_cfg() {
  local CMD="${@} --verbose --help --log-bin-index=$(mktemp -u)"
  local OUT=$(${CMD} 2>&1 1>/dev/null || echo $?)
  if [ -n "${OUT}" ]; then
    error "Config validation error, please check your configuration!"
    error "Command failed: ${CMD}"
    error "Error output: ${OUT}"
    exit 1
  fi
}
#
get_cfg_value() {
  local conf="${1}"; shift
  "${@}" --verbose --help --log-bin-index="$(mktemp -u)" 2>/dev/null | grep "^$conf " | awk '{ print $2 }'
}
#
start_server() {
  echo "Starting '$@'"
  # start the process and in case of error dump significant
  # part of error log to stderr for quicker debugging
  exec "$@" 2>&1 || debug_exit $?
}
#
message "Preparing ${PRODUCT}..."
#
message "Searching for custom MYSQL_CMD configs in ${INITDBDIR}..."
CFGS=$(find "${INITDBDIR}" -name '*.cnf')
if [[ -n "${CFGS}" ]]; then
  cp -vf "${CFGS}" /etc/mysql/conf.d/
fi
#
message "Validating configuration..."
validate_cfg "${@}"
DATADIR="$(get_cfg_value 'datadir' "$@")"
DATADIR=${DATADIR%/} # strip the trailing '/' if any
# Make sure error log is stored on persistent volume
LOG_ERROR="${DATADIR}/mysqld.err"
set -- "$@" "--log-error=${LOG_ERROR}"
INIT_MARKER="${DATADIR}/grastate.dat"
#
#################################################
# If database is initialized and we are to join #
# an existing cluster - recover position        #
#################################################
################################################# 
# If we are joining a cluster then skip         #
# initialization and start right away - we'll   #
# be getting SST anyways                        #
#################################################
if [[ -n ${WSREP_JOIN:=} || -f ${INIT_MARKER} ]]; then
  if [[ -n ${WSREP_JOIN} ]]; then
    set -- "$@" "--wsrep-cluster-address=gcomm://${WSREP_JOIN}"
    if [[ -f ${INIT_MARKER} ]]; then
      find /usr -name 'wsrep_recover' && \
      WSREP_POSITION_OPTION=$(wsrep_recover) && \
      set -- "$@" "${WSREP_POSITION_OPTION}"
    fi
  else
    set -- "$@" "--wsrep-new-cluster"
  fi
  start_server "$@"
  exit ${?}
fi
################################################
# Need to initialize the database before start #
################################################
file_env 'MYSQL_ROOT_PASSWORD'
if [[ -z "${MYSQL_ROOT_PASSWORD}" && -z "${MYSQL_ALLOW_EMPTY_PASSWORD:=}" && -z "${MYSQL_RANDOM_ROOT_PASSWORD:=}" ]]; then
  echo >&2 'error: database is uninitialized and password option is not specified '
  echo >&2 '  You need to specify one of MYSQL_ROOT_PASSWORD, MYSQL_ALLOW_EMPTY_PASSWORD and MYSQL_RANDOM_ROOT_PASSWORD'
  exit 1
fi
#
if [[ ! -d "${DATADIR}/${MYSQL_DB}" ]]; then
  rm -rf $DATADIR/* && mkdir -p "$DATADIR"

  message "Initializing data directory..."
  "$@" --initialize-insecure --tls-version='' || debug_exit $?
  message 'Data directory initialized'
fi
#
SOCKET="$(get_cfg_value 'socket' "$@")"
"$@" --skip-networking --socket="${SOCKET}" --wsrep-provider="none" &
PID="${!}"

MYSQL_CMD=( ${MYSQL_CLIENT} --protocol=socket -uroot -hlocalhost --socket="${SOCKET}" )
STARTED=0
while ps -uh --pid ${PID} > /dev/null; do
  if echo "SELECT @@wsrep_on;" | "${MYSQL_CMD[@]}" >/dev/null; then
    STARTED=1
    break
  fi
  message "${PRODUCT} initialization startup in progress..."
  sleep 1
done
if [[ "${STARTED}" -eq 0 ]]; then
  error "${PRODUCT} failed to start!"
  debug_exit 1
fi
#
if [[ "${MYSQL_INITDB_TZINFO}" -eq 1 ]]; then
  message "Loading TZINFO..."
  # sed is for https://bugs.mysql.com/bug.php?id=20545
  ${MYSQL_TZINFOTOSQL} /usr/share/zoneinfo \
  | sed 's/Local time zone must be set--see zic manual page/FCTY/' \
  | "${MYSQL_CMD[@]}" ${MYSQL_DB}
fi
#
file_env 'MYSQL_DATABASE'
if [[ -n "${MYSQL_DATABASE}" ]]; then
  message "Creating database ${MYSQL_DATABASE}"
  echo "CREATE DATABASE IF NOT EXISTS \`${MYSQL_DATABASE}\`" | "${MYSQL_CMD[@]}"
fi
#
file_env 'MYSQL_USER'
file_env 'MYSQL_PASSWORD'
if [[ -n "${MYSQL_USER}" ]] && [[ -n "${MYSQL_PASSWORD}" ]]; then
  message "Creating user ${MYSQL_USER} with password set"
  echo "CREATE USER '${MYSQL_USER}'@'%' IDENTIFIED BY '${MYSQL_PASSWORD}';" | "${MYSQL_CMD[@]}"
  if [[ -n "${MYSQL_DATABASE}" ]]; then
    message "Giving all privileges on ${MYSQL_DATABASE} to ${MYSQL_USER}..."
    echo "GRANT ALL ON \`${MYSQL_DATABASE}\`.* TO '${MYSQL_USER}'@'%';" | "${MYSQL_CMD[@]}"
  fi
  echo 'FLUSH PRIVILEGES ;' | "${MYSQL_CMD[@]}"
else
  message "Skipping MYSQL user creation, both MYSQL_USER and MYSQL_PASSWORD must be set"
fi
#
for _file in "${INITDBDIR}"/*; do
  case "${_file}" in
    *.sh)
      message "Running shell script ${_file}"
      . "${_file}"
      ;;
    *.sql)
      message "Running SQL file ${_file}"
      "${MYSQL_CMD[@]}" < "${_file}"
      echo
      ;;
    *.sql.gz)
      message "Running compressed SQL file ${_file}"
      zcat "${_file}" | "${MYSQL_CMD[@]}"
      echo
      ;;
    *)
      message "Ignoring ${_file}"
      ;;
  esac
done
#
if [[ "${MYSQL_ROOT_PASSWORD}" = RANDOM || ! -z "${MYSQL_RANDOM_ROOT_PASSWORD:=}" ]]; then
  export MYSQL_ROOT_PASSWORD="$(openssl rand -base64 24)"
  echo "GENERATED ROOT PASSWORD: $MYSQL_ROOT_PASSWORD"
else
  if [[ "${MYSQL_ROOT_PASSWORD}" = EMPTY || ! -z "${MYSQL_ALLOW_EMPTY_PASSWORD:=}" ]]; then
    warning "=-> Warning! Warning! Warning!"
    warning "EMPTY password is specified for image, your container is insecure!!!"
  fi
fi
#
# Disable binlog for the setup session
ROOT_SETUP="SET @@SESSION.SQL_LOG_BIN=0; "
# Reading password from docker filesystem (bind-mounted directory or file added during build)
file_env 'MYSQL_ROOT_HOST' '%'
if [ ! -z "${MYSQL_ROOT_HOST}" -a "${MYSQL_ROOT_HOST}" != 'localhost' ]; then
  # no, we don't care if read finds a terminating character in this heredoc
  # https://unix.stackexchange.com/questions/265149/why-is-set-o-errexit-breaking-this-read-heredoc-expression/265151#265151
  read -r -d '' ROOT_SETUP <<- EOSQL || true
    ${ROOT_SETUP}
    CREATE USER 'root'@'${MYSQL_ROOT_HOST}' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}'; 
    GRANT ALL ON *.* TO 'root'@'${MYSQL_ROOT_HOST}' WITH GRANT OPTION; 
EOSQL
  if [ ! -z "${MYSQL_ONETIME_PASSWORD:=}" ]; then
#  echo "ALTER USER 'root'@'%' PASSWORD EXPIRE;" | "${MYSQL_CMD[@]}"
    read -r -d '' ROOT_SETUP <<- EOSQL || true
    ${ROOT_SETUP}
    ALTER USER 'root'@'${MYSQL_ROOT_HOST}' PASSWORD EXPIRE; 
EOSQL
  fi
fi
if [[ "${MYSQL_ROOT_PASSWORD}" != EMPTY ]]; then
  message "ROOT password has been specified for image, updating account..."
#  echo "ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}';" | "${MYSQL_CMD[@]}"
  read -r -d '' ROOT_SETUP <<- EOSQL || true
    ${ROOT_SETUP}
    GRANT ALL ON *.* TO 'root'@'localhost' WITH GRANT OPTION; 
    ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}'; 
EOSQL
fi
read -r -d '' ROOT_SETUP <<- EOSQL || true
  ${ROOT_SETUP}
  FLUSH PRIVILEGES;
EOSQL
#
echo "${ROOT_SETUP}" | ${MYSQL_CMD[@]}
#
if ! kill -s TERM "${PID}" || ! wait "${PID}"; then
  error "${PRODUCT} init process failed!"
  exit 1
fi
#
# Finally
message "${PRODUCT} is starting!"
#
start_server "$@"