#!/bin/bash
# Startup script for this OTRS container.
#
# The script by default loads a fresh OTRS install ready to be customized through
# the admin web interface.
#
# If the environment variable OTRS_INSTALL is set to yes, then the default web
# installer can be run from localhost/otrs/installer.pl.
#
# If the environment variable OTRS_INSTALL="restore", then the configuration backup
# files will be loaded from ${OTRS_ROOT}/backups. This means you need to build
# the image with the backup files (sql and Confg.pm) you want to use, or, mount a
# host volume to map where you store the backup files to ${OTRS_ROOT}/backups.
#
# To change the default database and admin interface user passwords you can define
# the following env vars too:
# - OTRS_DB_PASSWORD to set the database password
# - OTRS_ROOT_PASSWORD to set the admin user 'root@localhost' password.
#
. ./util_functions.sh

#Default configuration values
DEFAULT_OTRS_DB_HOST="mariadb"
DEFAULT_OTRS_DB_PORT="3306"
DEFAULT_OTRS_ADMIN_EMAIL="admin@example.com"
DEFAULT_OTRS_ORGANIZATION="Example Company"
DEFAULT_OTRS_SYSTEM_ID="98"
DEFAULT_OTRS_AGENT_LOGO_HEIGHT="67"
DEFAULT_OTRS_AGENT_LOGO_RIGHT="38"
DEFAULT_OTRS_AGENT_LOGO_TOP="4"
DEFAULT_OTRS_AGENT_LOGO_WIDTH="270"
DEFAULT_OTRS_CUSTOMER_LOGO_HEIGHT="50"
DEFAULT_OTRS_CUSTOMER_LOGO_RIGHT="25"
DEFAULT_OTRS_CUSTOMER_LOGO_TOP="2"
DEFAULT_OTRS_CUSTOMER_LOGO_WIDTH="135"

DEFAULT_OTRS_FRONTEND_WEBPATH="/otrs-web/"
DEFAULT_OTRS_SCRIPT_ALIAS="otrs/"

OTRS_BACKUP_DIR="/var/otrs/backups"
OTRS_CONFIG_DIR="${OTRS_ROOT}/Kernel"
OTRS_CONFIG_MOUNT_DIR="/config"

[ -z "${OTRS_INSTALL}" ] && OTRS_INSTALL="no"

[ -z "${OTRS_DB_HOST}" ] && OTRS_DB_HOST="$DEFAULT_OTRS_DB_HOST"
[ -z "${OTRS_DB_PORT}" ] && OTRS_DB_PORT="$DEFAULT_OTRS_DB_PORT"
[ -z "${OTRS_FRONTEND_WEBPATH}" ] && OTRS_FRONTEND_WEBPATH="$DEFAULT_OTRS_FRONTEND_WEBPATH"
[ -z "${OTRS_SCRIPT_ALIAS}" ] && OTRS_SCRIPT_ALIAS="$DEFAULT_OTRS_SCRIPT_ALIAS"

export OTRS_SCRIPT_ALIAS_NO_TRSLASH=${OTRS_SCRIPT_ALIAS%/}
export OTRS_FRONTEND_WEBPATH OTRS_SCRIPT_ALIAS

function mysqlcmd() {
    mysql -uroot --protocol=TCP --host="${OTRS_DB_HOST}" --port="${OTRS_DB_PORT}" --password="${MYSQL_ROOT_PASSWORD}" "$@"
}

function create_db() {
  print_info "Creating OTRS database..."
  mysqlcmd -e "CREATE DATABASE IF NOT EXISTS otrs;"
  [ $? -gt 0 ] && print_error "Couldn't create OTRS database !!" && exit 1
  mysqlcmd -e " GRANT ALL ON otrs.* to 'otrs'@'%' identified by '$OTRS_DB_PASSWORD'";
  [ $? -gt 0 ] && print_error "Couldn't create database user !!" && exit 1
}

function restore_backup(){
  [ -z $1 ] && print_error "\n\e[1;31mERROR:\e[0m OTRS_BACKUP_DATE not set.\n" && exit 1
  set_variables
  copy_default_config

  #As this is a restore, drop database first.

  mysqlcmd -e 'use otrs'
  if [ $? -eq 0  ]; then
    if [ "$OTRS_DROP_DATABASE" == "yes" ]; then
      print_info "OTRS_DROP_DATABASE=\e[92m$OTRS_DROP_DATABASE\e[0m, Dropping existing database\n"
      mysqlcmd -e 'drop database otrs'
    else
      print_error "Couldn't load OTRS backup, databse already exists !!" && exit 1
    fi
  fi

  create_db
  update_config_password $OTRS_DB_PASSWORD

  # Make a copy of installed skins so they aren't overwritten by the backup.
  tmpdir=`mktemp -d`
  [ ! -z "$OTRS_AGENT_SKIN" ] && cp -rp ${SKINS_PATH}Agent $tmpdir/
  [ ! -z "$OTRS_CUSTOMER_SKIN" ] && cp -rp ${SKINS_PATH}Customer $tmpdir/
  # Run restore backup command
  ${OTRS_ROOT}/scripts/restore.pl -b $OTRS_BACKUP_DIR/$1 -d ${OTRS_ROOT}/
  [ $? -gt 0 ] && print_error "Couldn't load OTRS backup !!" && exit 1

  backup_version=`tar -xOf $OTRS_BACKUP_DIR/$1/Application.tar.gz ./RELEASE|grep -o 'VERSION = [^,]*' | cut -d '=' -f2 |tr -d '[[:space:]]'`
  OTRS_INSTALLED_VERSION=`echo $OTRS_VERSION|cut -d '-' -f1`
  print_warning "OTRS version of backup being restored: \e[1;31m${backup_version}\e[1;0m"
  print_warning "OTRS version of this container: \e[1;31m${OTRS_INSTALLED_VERSION}\e[1;0m"

  check_version "$OTRS_INSTALLED_VERSION" "$backup_version"
  if [ $? -eq 0 ]; then
    print_warning "Backup version older than current OTRS version, fixing..."
    # Update version on ${OTRS_ROOT}/RELEASE so it the website shows the correct version.
    sed -i -r "s/(VERSION *= *).*/\1$OTRS_INSTALLED_VERSION/" ${OTRS_ROOT}/RELEASE
    print_info "Done."
  fi

  # Restore configured password overwritten by restore
  update_config_password "$OTRS_DB_PASSWORD"
  # Copy back skins over restored files
  [ ! -z "$OTRS_CUSTOMER_SKIN" ] && cp -rfp $tmpdir/* ${SKINS_PATH} && rm -fr $tmpdir

  #Update the skin preferences  in the users from the backup
  set_users_skin
}

# return 0 if program version is equal or greater than check version
check_version() {
    local version=$1 check=$2
    local winner=$(echo -e "$version\n$check" | sed '/^$/d' | sort -nr | head -1)
    [[ "$winner" = "$version" ]] && return 0
    return 1
}

function random_string() {
  echo `cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 8 | head -n 1`
}

function update_config_password() {
  #Change database password on configuration file
  sed  -i "s/\($Self->{DatabasePw} *= *\).*/\1'$1';/" ${OTRS_ROOT}/Kernel/Config.pm
}

function copy_default_config() {
  #print_info "Copying configuration file..."
  #cp -f "${OTRS_ROOT}/docker/defaults/Config.pm.default" "${OTRS_ROOT}/Kernel/Config.pm"
  #[ $? -gt 0 ] && print_error "\n\e[1;31mERROR:\e[0m Couldn't load OTRS config file !!\n" && exit 1
    :
}

function set_variables() {
  [ -z "${OTRS_HOSTNAME}" ] && OTRS_HOSTNAME="otrs-`random_string`" && print_info "OTRS_HOSTNAME not set, setting hostname to '$OTRS_HOSTNAME'"
  [ -z "${OTRS_ADMIN_EMAIL}" ] && print_info "OTRS_ADMIN_EMAIL not set, setting admin email to '$DEFAULT_OTRS_ADMIN_EMAIL'" && OTRS_ADMIN_EMAIL=$DEFAULT_OTRS_ADMIN_EMAIL
  [ -z "${OTRS_ORGANIZATION}" ] && print_info "OTRS_ORGANIZATION setting organization to '$DEFAULT_OTRS_ORGANIZATION'" && OTRS_ORGANIZATION=$DEFAULT_OTRS_ORGANIZATION
  [ -z "${OTRS_SYSTEM_ID}" ] && print_info "OTRS_SYSTEM_ID not set, setting System ID to '$DEFAULT_OTRS_SYSTEM_ID'"  && OTRS_SYSTEM_ID=$DEFAULT_OTRS_SYSTEM_ID
  [ -z "${OTRS_DB_PASSWORD}" ] && OTRS_DB_PASSWORD=`random_string` && print_info "OTRS_DB_PASSWORD not set, setting password to '$OTRS_DB_PASSWORD'"
  [ -z "${OTRS_ROOT_PASSWORD}" ] && print_info "OTRS_ROOT_PASSWORD not set, setting password to '$DEFAULT_OTRS_PASSWORD'" && OTRS_ROOT_PASSWORD=$DEFAULT_OTRS_PASSWORD

  #Set default skin to use for Agent interface
  [ ! -z "${OTRS_AGENT_SKIN}" ] && print_info "Setting Agent Skin to '$OTRS_AGENT_SKIN'"
  if [ ! -z "${OTRS_AGENT_LOGO}" ]; then
    print_info "Setting Agent Logo to: '$OTRS_AGENT_LOGO'"
    [ -z "${OTRS_AGENT_LOGO_HEIGHT}" ] && print_info "OTRS_AGENT_LOGO_HEIGHT not set, setting default value '$DEFAULT_OTRS_AGENT_LOGO_HEIGHT'" && OTRS_AGENT_LOGO_HEIGHT=$DEFAULT_OTRS_AGENT_LOGO_HEIGHT
    [ -z "${OTRS_AGENT_LOGO_RIGHT}" ] && print_info "OTRS_AGENT_LOGO_RIGHT not set, setting default value '$DEFAULT_OTRS_AGENT_LOGO_RIGHT'" && OTRS_AGENT_LOGO_RIGHT=$DEFAULT_OTRS_AGENT_LOGO_RIGHT
    [ -z "${OTRS_AGENT_LOGO_TOP}" ] && print_info "OTRS_AGENT_LOGO_TOP not set, setting default value '$DEFAULT_OTRS_AGENT_LOGO_TOP'" && OTRS_AGENT_LOGO_TOP=$DEFAULT_OTRS_AGENT_LOGO_TOP
    [ -z "${OTRS_AGENT_LOGO_WIDTH}" ] && print_info "OTRS_AGENT_LOGO_WIDTH not set, setting default value '$DEFAULT_OTRS_AGENT_LOGO_WIDTH'" && OTRS_AGENT_LOGO_WIDTH=$DEFAULT_OTRS_AGENT_LOGO_WIDTH
  fi
  [ ! -z "${OTRS_CUSTOMER_SKIN}" ] && print_info "Setting Customer Skin to '$OTRS_CUSTOMER_SKIN'"
  if [ ! -z "${OTRS_CUSTOMER_LOGO}" ]; then
    print_info "Setting Customer Logo to: '$OTRS_CUSTOMER_LOGO'"
    [ -z "${OTRS_CUSTOMER_LOGO_HEIGHT}" ] && print_info "OTRS_CUSTOMER_LOGO_HEIGHT not set, setting default value '$DEFAULT_OTRS_CUSTOMER_LOGO_HEIGHT'" && OTRS_CUSTOMER_LOGO_HEIGHT=$DEFAULT_OTRS_CUSTOMER_LOGO_HEIGHT
    [ -z "${OTRS_CUSTOMER_LOGO_RIGHT}" ] && print_info "OTRS_CUSTOMER_LOGO_RIGHT not set, setting default value '$DEFAULT_OTRS_CUSTOMER_LOGO_RIGHT'" && OTRS_CUSTOMER_LOGO_RIGHT=$DEFAULT_OTRS_CUSTOMER_LOGO_RIGHT
    [ -z "${OTRS_CUSTOMER_LOGO_TOP}" ] && print_info "OTRS_CUSTOMER_LOGO_TOP not set, setting default value '$DEFAULT_OTRS_CUSTOMER_LOGO_TOP'" && OTRS_CUSTOMER_LOGO_TOP=$DEFAULT_OTRS_CUSTOMER_LOGO_TOP
    [ -z "${OTRS_CUSTOMER_LOGO_WIDTH}" ] && print_info "OTRS_CUSTOMER_LOGO_WIDTH not set, setting default value '$DEFAULT_OTRS_CUSTOMER_LOGO_WIDTH'" && OTRS_CUSTOMER_LOGO_WIDTH=$DEFAULT_OTRS_CUSTOMER_LOGO_WIDTH
  fi
}

function load_defaults() {
    set_variables
    # Check if a host-mounted volume for configuration storage was added to this
    # container
    check_host_mount_dir
    copy_default_config
    update_config_password "$OTRS_DB_PASSWORD"

    # Add default config options
    sed -i "/#[[:space:]]*\$DIBI\$[[:space:]]*$/a\\
\n\$Self->{'FQDN'} = '$OTRS_HOSTNAME';\
\n\$Self->{'ScriptAlias'} = '$OTRS_SCRIPT_ALIAS';\
\n\$Self->{'Frontend::WebPath'} = '$OTRS_FRONTEND_WEBPATH';\
\n\$Self->{'AdminEmail'} = '$OTRS_ADMIN_EMAIL';\
\n\$Self->{'DatabaseHost'} = '$OTRS_DB_HOST';\
\n\$Self->{'Organization'} = '$OTRS_ORGANIZATION';\
\n\$Self->{'CustomerHeadline'} = '$OTRS_ORGANIZATION';\
\n\$Self->{'SystemID'} = '$OTRS_SYSTEM_ID';\
\n\$Self->{'PostMaster::PreFilterModule::NewTicketReject::Sender'} = 'noreply@${OTRS_HOSTNAME}';\
\n\$Self->{'PostmasterFollowUpSearchInRaw'} = '1';\
\n\$Self->{'PostmasterFollowUpSearchInBody'} = '1';\
\n\$Self->{'PostmasterFollowUpSearchInAttachment'} = '1';\
\n\$Self->{'PostmasterFollowUpSearchInReferences'} = '1';\
\n\$Self->{DatabaseDSN} = \"DBI:mysql:database=\$Self->{Database};host=\$Self->{DatabaseHost};\";"\
        ${OTRS_ROOT}/Kernel/Config.pm

    # Check if database doesn't exists yet (it could if this is a container redeploy)
    if ! mysqlcmd -e 'use otrs'; then
        create_db

        # Check that a backup isn't being restored
        if [ "$OTRS_INSTALL" == "no" ]; then

            print_info "Loading default db schema..."
            mysqlcmd otrs < "${OTRS_ROOT}/scripts/database/otrs-schema.mysql.sql"
            [ $? -ne 0 ] && print_error "\n\e[1;31mERROR:\e[0m Couldn't load OTRS database schema !!\n" && exit 1
            
            print_info "Loading initial db inserts..."
            mysqlcmd otrs < "${OTRS_ROOT}/scripts/database/otrs-initial_insert.mysql.sql"
            [ $? -ne 0 ] && print_error "\n\e[1;31mERROR:\e[0m Couldn't load OTRS database initial inserts !!\n" && exit 1

            print_info "Loading db post initialization..."
            mysqlcmd otrs < "${OTRS_ROOT}/scripts/database/otrs-schema-post.mysql.sql"
            [ $? -ne 0 ] && print_error "\n\e[1;31mERROR:\e[0m Couldn't load OTRS database post initialization !!\n" && exit 1

        fi
    else
        print_warning "otrs database already exists, Ok."
    fi
}

function set_default_language() {
    if [ ! -z $OTRS_LANGUAGE ]; then
        print_info "Setting default language to: \e[92m'$OTRS_LANGUAGE'\e[0m"
        sed -i "/#[[:space:]]*\$DIBI\$[[:space:]]*$/a\\
    \n\$Self->{'DefaultLanguage'} = '$OTRS_LANGUAGE';"\
            ${OTRS_ROOT}/Kernel/Config.pm
    fi
}

function set_ticker_counter() {
  if [ ! -z "${OTRS_TICKET_COUNTER}" ]; then
    print_info "Setting the start of the ticket counter to: \e[92m'$OTRS_TICKET_COUNTER'\e[0m"
    echo "$OTRS_TICKET_COUNTER" > ${OTRS_ROOT}/var/log/TicketCounter.log
  fi
  if [ ! -z $OTRS_NUMBER_GENERATOR ]; then
    print_info "Setting ticket number generator to: \e[92m'$OTRS_NUMBER_GENERATOR'\e[0m"
    sed -i "/#[[:space:]]*\$DIBI\$[[:space:]]*$/a \$Self->{'Ticket::NumberGenerator'} =  'Kernel::System::Ticket::Number::${OTRS_NUMBER_GENERATOR}';"\
     ${OTRS_ROOT}/Kernel/Config.pm
  fi
}

function set_skins() {
  [ ! -z $OTRS_AGENT_SKIN ] &&  sed -i "/#[[:space:]]*\$DIBI\$[[:space:]]*$/a\\
\n\$Self->{'Loader::Agent::DefaultSelectedSkin'} =  '$OTRS_AGENT_SKIN';\
\n\$Self->{'Loader::Customer::SelectedSkin'} =  '$OTRS_CUSTOMER_SKIN';"\
 ${OTRS_ROOT}/Kernel/Config.pm

  #Set Agent interface logo
  [ ! -z $OTRS_AGENT_LOGO ] && set_agent_logo

  #Set Customer interface logo
  [ ! -z $OTRS_CUSTOMER_LOGO ] && set_customer_logo
}

function set_users_skin(){
  print_info "Updating default skin for users in backup..."
  mysqlcmd -e "UPDATE user_preferences SET preferences_value = '$OTRS_AGENT_SKIN' WHERE preferences_key = 'UserSkin'" otrs
  [ $? -gt 0 ] && print_error "\n\e[1;31mERROR:\e[0m Couldn't change default skin for existing users !!\n"
}

function set_agent_logo() {
  set_logo "Agent" $OTRS_AGENT_LOGO_HEIGHT $OTRS_AGENT_LOGO_RIGHT $OTRS_AGENT_LOGO_TOP $OTRS_AGENT_LOGO_WIDTH $OTRS_AGENT_LOGO
}

function set_customer_logo() {
  set_logo "Customer" $OTRS_CUSTOMER_LOGO_HEIGHT $OTRS_CUSTOMER_LOGO_RIGHT $OTRS_CUSTOMER_LOGO_TOP $OTRS_CUSTOMER_LOGO_WIDTH $OTRS_CUSTOMER_LOGO
}

function set_logo () {
  interface=$1
  logo_height=$2
  logo_right=$3
  logo_top=$4
  logo_width=$5
  logo_url=$6

  sed -i "/#[[:space:]]*\$DIBI\$[[:space:]]*$/a\\
\n\$Self->{'${interface}Logo'} =  {\n'StyleHeight' => '${logo_height}px',\
\n'StyleRight' => '${logo_right}px',\
\n'StyleTop' => '${logo_top}px',\
\n'StyleWidth' => '${logo_width}px',\
\n'URL' => '$logo_url'\n};" ${OTRS_ROOT}/Kernel/Config.pm
}

# function set_customer_logo() {
#   sed -i "/#[[:space:]]*\$DIBI\$[[:space:]]*$/a\ \$Self->{'CustomerLogo'} =  {\n'StyleHeight' => '${OTRS_CUSTOMER_LOGO_HEIGHT}px',\n'StyleRight' => '${OTRS_CUSTOMER_LOGO_RIGHT}px',\n'StyleTop' => '${OTRS_CUSTOMER_LOGO_TOP}px',\n'StyleWidth' => '${OTRS_CUSTOMER_LOGO_WIDTH}px',\n'URL' => '$OTRS_CUSTOMER_LOGO'\n};" ${OTRS_ROOT}/Kernel/Config.pm
# }

function set_fetch_email_time(){
  if [ ! -z $OTRS_POSTMASTER_FETCH_TIME ]; then
    print_info "Setting Postmaster fetch emails time to \e[92m$OTRS_POSTMASTER_FETCH_TIME\e[0m minutes"

    if [ $OTRS_POSTMASTER_FETCH_TIME -eq 0 ]; then

      #Disable email fetching
      sed -i -e '/otrs.PostMasterMailbox.pl/ s/^#*/#/' /var/spool/cron/otrs
    else
      #sed -i -e '/otrs.PostMasterMailbox.pl/ s/^#*//' /var/spool/cron/otrs
      ${OTRS_ROOT}/scripts/otrs_postmaster_time.sh $OTRS_POSTMASTER_FETCH_TIME
    fi
  fi
}

function check_host_mount_dir(){
  #If $OTRS_CONFIG_MOUNT_DIR exists it means a host-mounted volume is present
  #to store OTRS configuration outside the container. Then we need to copy the
  #contents of $OTRS_CONFIG_DIR to that directory, remove it and symlink
  #$OTRS_CONFIG_MOUNT_DIR to $OTRS_CONFIG_DIR
  print_info "Checking if host-mounted volumes are present... "
  if [ -d ${OTRS_CONFIG_MOUNT_DIR} ];
  then
    if [ "$(ls -A ${OTRS_CONFIG_MOUNT_DIR})" ];
    then
      print_warning "Found non-empty host-mounted volume directory for OTRS configuration at ${OTRS_CONFIG_MOUNT_DIR} "
    else
      print_info "Found empty host-mounted volume directory, copying OTRS configuration to ${OTRS_CONFIG_MOUNT_DIR}..."
      cp -rp ${OTRS_CONFIG_DIR}/* ${OTRS_CONFIG_MOUNT_DIR}
    fi
    if [ $? -eq 0 ];
    then
      print_info "Deleting ${OTRS_CONFIG_DIR}... "
      rm -rf ${OTRS_CONFIG_DIR}
    else
      print_error "ERROR: Can't copy OTRS configuration to host-mounted volume ${OTRS_CONFIG_MOUNT_DIR}" && exit 1
    fi
  fi
  
  #ln -s ${OTRS_CONFIG_MOUNT_DIR} ${OTRS_CONFIG_DIR}
  mkdir -p "${OTRS_CONFIG_DIR}"
  if [ -e "${OTRS_CONFIG_MOUNT_DIR}" ]; then
      print_info "Linking back \e[92m${OTRS_CONFIG_MOUNT_DIR}\e[0m to \e[92m${OTRS_CONFIG_DIR}\e[0m..."
      cp -rp ${OTRS_CONFIG_MOUNT_DIR}/* ${OTRS_CONFIG_DIR}
      if [ $? -eq 0 ];
      then
          print_info "Done."
      else
          print_error "Can't create symlink to OTRS configuration on host-mounted volume ${OTRS_CONFIG_MOUNT_DIR}" && exit 1
      fi
  else
      print_info "No configuration directory ${OTRS_CONFIG_MOUNT_DIR}"
  fi
}
