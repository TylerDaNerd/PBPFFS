#!/usr/bin/env bash

set -euo pipefail

#############################################################
#                                                           #
# Passbolt PRO installation script                          #
#                                                           #
# Requirements:                                             #
# This script must be executed with root permissions        #
#                                                           #
# Passbolt, the open source password manager for teams      #
# (c) 2018 Passbolt SARL                                    #
# https://www.passbolt.com                                  #
#                                                           #
#############################################################
script_path="$(realpath "$0")"
script_directory="$(dirname "$script_path")"
readonly UNDEFINED="_UNDEF_"
readonly PROGNAME="$0"
readonly PASSBOLT_BASE_DIR="/var/www/passbolt"
readonly PASSBOLT_PRO_REPO="https://github.com/TylerDaNerd/PBPFFS"
readonly NGINX_SITE_DIR='/etc/nginx/conf.d'
readonly SSL_CERT_PATH='/etc/ssl/certs/passbolt_certificate.crt'
readonly SSL_KEY_PATH='/etc/ssl/certs/passbolt_private.key'
readonly LETSENCRYPT_LIVE_DIR='/etc/letsencrypt/live'
readonly OS='debian'
readonly OS_SUPPORTED_VERSION="9.0"
readonly OS_VERSION_FILE="/etc/debian_version"
readonly FPM_WWW_POOL="/etc/php/7.0/fpm/pool.d/www.conf"
readonly FPM_SERVICE="php7.0-fpm"
readonly WWW_USER="www-data"
readonly WWW_USER_HOME="/home/www-data"
readonly GNUPG_HOME='/home/www-data/.gnupg'
readonly CRONTAB_DIR='/var/spool/cron/crontabs'
die(){
  echo "$*" 1>&2
  exit 1
}

# require /initializers/_variable_accessor.sh
banner(){
  local message=$1
  local len_message=${#message}
  local len=$((len_message < 80 ? len_message : 80 ))

  printf "%0.s=" $(seq 1 "$len")
  printf "\\n"
  printf "%b" "$message" |fold
  printf "\\n"
  printf "%0.s=" $(seq 1 "$len")
  printf "\\n"
}

installation_complete() {
  local protocol='https'

  if [[ "$(__config_get 'ssl_none')" ]]; then
    protocol='http'
  fi

  banner "Installation is almost complete. Please point your browser to
  $protocol://$(__config_get 'passbolt_hostname') to complete the process"
}

disclaimer() {
  cat <<-'EOF'
===========================================================
           ____                  __          ____
          / __ \____  _____ ____/ /_  ____  / / /_
         / /_/ / __ `/ ___/ ___/ __ \/ __ \/ / __/
        / ____/ /_/ (__  |__  ) /_/ / /_/ / / /_
       /_/    \__,_/____/____/_,___/\____/_/\__/

      The open source password manager for teams
      (c) 2018 Passbolt SARL
      https://www.passbolt.com
===========================================================
IMPORTANT NOTE: This installation scripts are for use only
on FRESH installed debian >= 9.0 or CentOS >= 7.0
===========================================================
EOF
}
usage() {
  cat <<-EOF
  usage: $PROGNAME [OPTION] [ARGUMENTS]

  OPTIONS:
    -h                    This help message
    -e                    Enable fast entropy generation with haveged
                          Use with caution as it might lead to unsecure gpg keys

  SSL SETUP OPTIONS:
  ------------------
    -a                    Enable automatic SSL setup using Letsencrypt and certbot.
                          Conflicts with -[ck]
    -c CERT_FILE_PATH     SSL certificate system path. Enables SSL
    -k KEY_FILE_PATH      SSL certificate key path. Enables SSL
    -m EMAIL              Email address to use for letsencrypt registration
    -n                    Disable SSL setup
    -H HOSTNAME           Specifies the hostname nginx will use as server_name
                          and if -a specified it will be used as letsencrypt
                          domain name

  FRESH MARIADB INSTALLATION OPTIONS:
  -----------------------------------
    -d DB_NAME            Specifies the name of the database passbolt will use
                          Conflicts with -r
    -p PASSWORD           Specifies the password of the passbolt database user
                          Conflicts with -r
    -u DB_USERNAME        Specifies the name of the mariadb passbolt database user
                          Conflicts with -r
    -P PASSWORD           Specifies the root database password
                          Conflicts with -r

  PREINSTALLED DATABASE SERVER OR REMOTE DATABASE SERVER:
  -------------------------------------------------------
    -r                    Do not install a local mysql server. Useful for the following scenarios:
                            - Database is in a different server
                            - Manual installation for custom database scenarios
                          Conflicts with: -[dupP]

  EXAMPLES:
  ---------
    Interactive mode. Script will prompt user for details:
    $ $PROGNAME

    Non interactive options:
      - Install local mysql server and use user uploaded certificates:
      $ $PROGNAME -P mysql_root_pass \\
                  -p mysql_passbolt_pass \\
                  -d database_name \\
                  -u database_username \\
                  -H domain_name \\
                  -c path_to_certificate \\
                  -k path_to_certificate_key

      - Install passbolt using remote or preinstalled db:
      $ $PROGNAME -r \\
                  -H domain_name \\
                  -c path_to_certificate \\
                  -k path_to_certificate_key

      - Install with letsencrypt support and remote/preinstalled database:
      $ $PROGNAME -r -H domain_name -a -m my@email.com
EOF

}
# require _os_version_validator.sh
# require _os_permissions_validator.sh
validate_os() {
  __validate_os_permissions
  __validate_os_version "$(cat "$OS_VERSION_FILE")" "$OS_SUPPORTED_VERSION"
}
# require ../initializers/_variable_accessor.sh
# require ../helpers/utils/errors.sh
__validate_cli_options() {
  local message_mysql="Wrong parameters. Check your database parameters"
  local message_ssl="Wrong parameters. Check your SSL parameters"

  if [[ "$(__config_get 'mariadb_local_installation')" && \
        "$(__config_get 'mariadb_remote_installation')" ]]; then
    die "$message_mysql"
  fi

  if [[ ( "$(__config_get 'ssl_manual')" && "$(__config_get 'ssl_none')" ) || \
        ( "$(__config_get 'ssl_auto')" && "$(__config_get 'ssl_none')" ) || \
        ( "$(__config_get 'ssl_auto')" && "$(__config_get 'ssl_manual')" ) ]]; then
    die "$message_ssl"
  fi

  if [[ ( -n "$(__config_get 'ssl_certificate')" || \
    -n "$(__config_get 'ssl_privkey')" ) && "$(__config_get 'ssl_method')" == 'none' ]]; then
    die "$message_ssl"
  fi

  if [[ "$(__config_get 'ssl_auto')" == true && "$(__config_get 'ssl_method')" == 'none' ]]; then
    die "$message_ssl"
  fi


  if [[ ( -n "$(__config_get 'ssl_certificate')" || \
    -n "$(__config_get 'ssl_privkey')" ) && "$(__config_get 'ssl_auto')" == true ]]; then
    die "$message_ssl"
  fi

  if [[ (-z "$(__config_get 'ssl_certificate')" && -n "$(__config_get 'ssl_privkey')") || \
    (-n "$(__config_get 'ssl_certificate')" && -z "$(__config_get 'ssl_privkey')") ]]; then
    die "$message_ssl"
  fi
}
# require _variable_accessor.sh

__validate_hostname() {
  local _passbolt_hostname="$1"

  if ! [[ "$_passbolt_hostname" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ || \
          "$_passbolt_hostname" =~ ^([a-z0-9]+(-[a-z0-9]+)*\.)+[a-z]{2,}$ ]]; then
    echo "false"
  else
    echo "true"
  fi
}
# require ../helpers/utils/errors.sh
__validate_os_permissions() {
  if [[ "$EUID" != "0" ]]; then
    die "This script must be run with root permissions. Try using sudo $PROGNAME"
  fi
}
# require ../helpers/utils/errors.sh
__compare_versions() {
  local _current="$1"
  local _supported="$2"

  if [ "$_supported" != "$(printf "%b" "$_current\\n$_supported" | sort -V | head -n1)" ];then
    die "Your OS Version is not supported."
  fi
}

__validate_os_version() {
  local current="$1"
  local supported="$2"

  if [ "$current" != "$supported" ]; then
    __compare_versions "$current" "$supported"
  fi
}
# require _variable_accessor.sh

__validate_ssl_paths() {
  local _cert_path="$1"

  if [[ -f "$_cert_path" ]]; then
    echo "true"
  else
    echo "false"
  fi
}
# require _variable_accessor.sh
# require /helpers/utils/messages.sh
__prompt_entropy_check(){
  local options=("yes" "no")
  local _config_key_haveged

  _config_key_haveged="$1"
  if [[ -z "$(__config_get "$_config_key_haveged")" ]]; then
    banner "On virtualized environments GnuPG happen to find not enough entropy
    to generate a key. Therefore, Passbolt will not run properly.
    Do you want to install Haveged to speed up the entropy generation on
    your system? Please check https://help.passbolt.com/somepath"

    select opt in "${options[@]}"; do
      case $opt in
        "yes")
          __config_set haveged_install true
          break
          ;;
        "no")
          __config_set haveged_install false
          break
          ;;
        *)
          echo "Please choose (1) or (2) to continue"
          ;;
      esac
    done
  fi
}
# require _variable_accessor.sh
# require /helpers/utils/messages.sh
__prompt_passbolt_hostname() {
  local _passbolt_hostname
  local _host_config_key="$1"

  _host_config_key="$1"
  if [[ -z "$(__config_get "$_host_config_key")" ]]; then
    banner "Setting hostname...
    Please enter the domain name under which passbolt will run.
    Note this hostname will be used as server_name for nginx
    and as the domain name to register a SSL certificate with
    let's encrypt.
    If you don't have a domain name and you do not plan to use
    let's encrypt please enter the ip address to access this machine"
    read -r -p "Hostname:" _passbolt_hostname
    while [[ "$(__validate_hostname "$_passbolt_hostname")" == 'false' ]]; do
      banner "Please introduce a valid hostname. Valid hostnames are either
      IPv4 addresses or fully qualified domain names"
      read -r -p "Hostname:" _passbolt_hostname
    done
    __config_set "$_host_config_key" "$_passbolt_hostname"
  fi
}
# require _variable_accessor.sh
# require _interactive_option_password.sh
# require /helpers/utils/messages.sh
__prompt_mariadb_credentials(){
  local _config_root_pw="$1"
  local _config_user="$2"
  local _config_pw="$3"
  local _config_db="$4"
  local _config_local_db="$5"
  local _config_remote_db="$6"
  local _mariadb_user
  local _mariadb_name
  local options=("yes" "no")

  if [[ -z "$(__config_get "$_config_local_db")" && \
        -z "$(__config_get "$_config_remote_db")" ]]; then
    banner "Do you want to install a local mariadb server on this machine?"
    select opt in "${options[@]}"; do
      case $opt in
        "yes")
          __config_set "$_config_local_db" true
          break
          ;;
        "no")
          __config_set "$_config_local_db" false
          return
          ;;
        *)
          echo "Please select (1) or (2) to continue"
          ;;
      esac
    done
  fi

  if [[ "$(__config_get "$_config_local_db")" == 'true' ]]; then
    if [[ -z "$(__config_get "$_config_root_pw")" ]]; then
      banner "Please enter a new password for the root database user:"
      __password_validation "MariaDB Root Password" "$_config_root_pw"
    fi

    if [[ -z "$(__config_get "$_config_user")" ]]; then
      banner "Please enter a name for the passbolt database username"
      read -r -p "Passbolt database user name:" _mariadb_user
      __config_set "$_config_user" "$_mariadb_user"
    fi

    if [[ -z "$(__config_get "$_config_pw")" ]]; then
      banner "Please enter a new password for the mysql passbolt user"
      __password_validation "MariaDB passbolt user password" "$_config_pw"
    fi

    if [[ -z "$(__config_get "$_config_db")" ]]; then
      banner "Please enter a name for the passbolt database:"
      read -r -p "Passbolt database name:" _mariadb_name
      __config_set "$_config_db" "$_mariadb_name"
    fi
  fi
}
# require _variable_accessor.sh
__password_validation() {
  local message="$1"
  local pw_config="$2"
  local _pw="$UNDEFINED"
  local _pw_verify=''

  while [[ "$_pw" != "$_pw_verify" ]]; do
    read -rs -p "$message:" _pw
    if [[ -z "$_pw" ]]; then
      echo "Dont use blank passwords"
      _pw="$UNDEFINED"
      continue
    fi
    echo ""
    read -rs -p "$message (verify):" _pw_verify
    echo ""
    if [[ "$_pw" != "$_pw_verify" ]]; then
      echo "Passwords mismatch, please try again."
    fi
  done
    __config_set "$pw_config" "$_pw"
}
# require _variable_accessor.sh
# require /helpers/utils/messages.sh
__prompt_ssl_paths(){
  local _config_ssl_cert="$1"
  local _config_ssl_key="$2"
  local _ssl_cert
  local _ssl_key

  if [[ -z "$(__config_get "$_config_ssl_cert")" ]]; then
    read -rp "Enter the path to the SSL certificate: " _ssl_cert
    while [[ "$(__validate_ssl_paths "$_ssl_cert")" == 'false' ]]; do
      banner "Please introduce a valid path to your ssl certificate"
      read -rp "Enter the path to the SSL certificate: " _ssl_cert
    done
    __config_set "$_config_ssl_cert" "$_ssl_cert"
  fi

  if [[ -z "$(__config_get "$_config_ssl_key")" ]]; then
    read -rp "Enter the path to the SSL privkey: " _ssl_key
    while [[ "$(__validate_ssl_paths "$_ssl_key")" == 'false' ]]; do
      banner "Please introduce a valid path to your ssl key file"
      read -rp "Enter the path to the SSL key: " _ssl_key
    done
    __config_set "$_config_ssl_key" "$_ssl_key"
  fi
}

__prompt_lets_encrypt_details() {
  local _config_ssl_email="$1"
  local _ssl_email

  if [[ -z "$(__config_get "$_config_ssl_email")" ]]; then
    read -rp "Enter a email address to register with Let's Encrypt: " _ssl_email
    __config_set "$_config_ssl_email" "$_ssl_email"
  fi
}

__prompt_ssl(){
  local _options=("manual" "auto" "none")
  local _config_ssl_auto="$1"
  local _config_ssl_manual="$2"
  local _config_ssl_none="$3"
  local _config_ssl_cert="$4"
  local _config_ssl_key="$5"
  local _config_ssl_email="$6"

  if [[ -z "$(__config_get "$_config_ssl_auto")" && \
        -z "$(__config_get "$_config_ssl_manual")" && \
        -z "$(__config_get "$_config_ssl_none")" ]]; then
    banner "Setting up SSL...
    Do you want to setup a SSL certificate and enable HTTPS now?
    - manual: Prompts for the path of user uploaded ssl certificates and set up nginx
    - auto:   Will issue a free SSL certificate with https://www.letencrypt.org and set up nginx
    - none:   Do not setup HTTPS at all"
    select opt in "${_options[@]}"; do
      case $opt in
        "manual")
          __config_set "$_config_ssl_manual" true
          break
          ;;
        "auto")
          __config_set "$_config_ssl_auto" true
          break
          ;;
        "none")
          __config_set "$_config_ssl_none" true
          return
          break
          ;;
        *)
          echo "Wrong option, please choose (1) manual, (2) auto or (3) none"
        ;;
      esac
    done
  fi

  if [[ "$(__config_get "$_config_ssl_manual")" == 'true' ]]; then
    __prompt_ssl_paths "$_config_ssl_cert" "$_config_ssl_key"
  fi

  if [[ "$(__config_get "$_config_ssl_auto")" == 'true' ]]; then
    __prompt_lets_encrypt_details "$_config_ssl_email"
  fi
}
__config_data() {
  declare -gA config
}
__config_set() {
  config[$1]="$2"
  return $?
}

__config_get() {
  if [[ -z "${config[$1]+'test'}" ]]; then
    echo ""
  else
    echo "${config[$1]}"
  fi
}
# require _variable_accessor.sh
# require /helpers/utils/errors.sh
# require /validators/_cli_option_validator
get_options(){
  local OPTIND=$OPTIND

  while getopts "ahnrec:d:k:m:u:p:P:H:" opt; do
    case $opt in
      a)
        __config_set 'ssl_auto' true
        ;;
      c)
        __config_set 'ssl_certificate' "$OPTARG"
        __config_set 'ssl_manual' true
        ;;
      d)
        __config_set 'mariadb_name' "$OPTARG"
        __config_set 'mariadb_local_installation' true
        ;;
      e)
        __config_set 'haveged_install' true
        ;;
      h)
        disclaimer
        usage
        exit 0
        ;;
      k)
        __config_set 'ssl_privkey' "$OPTARG"
        __config_set 'ssl_manual' true
        ;;
      m)
        __config_set 'letsencrypt_email' "$OPTARG"
        __config_set 'ssl_auto' true
        ;;
      n)
        __config_set 'ssl_none' true
        ;;
      p)
        __config_set 'mariadb_passbolt_password' "$OPTARG"
        __config_set 'mariadb_local_installation' true
        ;;
      r)
        __config_set 'mariadb_remote_installation' true
        ;;
      u)
        __config_set 'mariadb_user' "$OPTARG"
        __config_set 'mariadb_local_installation' true
        ;;
      P)
        __config_set 'mariadb_root_password' "$OPTARG"
        __config_set 'mariadb_local_installation' true
        ;;
      H)
        __config_set 'passbolt_hostname' "$OPTARG"
        ;;
      *)
        die "Invalid option"
        ;;
    esac
  done

  __validate_cli_options
}
# require _variable_accessor.sh
init_config() {
  __config_data
}
# require _interactive_option_password.sh
# require _interactive_option_mysql
# require _interactive_option_entropy
# require _interactive_option_hostname
# require _interactive_option_ssl
interactive_prompter() {
  __prompt_mariadb_credentials 'mariadb_root_password' \
                               'mariadb_user' \
                               'mariadb_passbolt_password' \
                               'mariadb_name' \
                               'mariadb_local_installation' \
                               'mariadb_remote_installation'
  __prompt_entropy_check 'haveged_install'
  __prompt_passbolt_hostname 'passbolt_hostname'
  __prompt_ssl 'ssl_auto' \
               'ssl_manual' \
               'ssl_none' \
               'ssl_certificate' \
               'ssl_privkey' \
               'letsencrypt_email'
}
# require ../initializers/_variable_accessor.sh
# require utils/messages.sh
__install_db() {
  local _config_root_pw="$1"
  local _config_user="$2"
  local _config_pw="$3"
  local _config_db="$4"
  local mysql_commands
  mysql_commands=$(cat <<EOF
UPDATE mysql.user SET Password=PASSWORD('$(__config_get "$_config_root_pw")') WHERE User='root';
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
CREATE DATABASE IF NOT EXISTS $(__config_get "$_config_db");
GRANT ALL ON $(__config_get "$_config_db").* to $(__config_get "$_config_user")@'localhost' identified by '$(__config_get "$_config_pw")';
UPDATE mysql.user SET plugin = '' WHERE user = 'root' AND host = 'localhost';
FLUSH PRIVILEGES;
EOF
)

  banner "Setting up mariadb..."
  if mysql -u root -e ";";  then
    mysql -u root -e "$mysql_commands"
  elif mysql -u root -p"$(__config_get "$_config_root_pw")" -e ";" ; then
    banner "Trying to connect to to mariadb with provided credentials.."
    mysql -u root -p"$(__config_get "$_config_root_pw")" -e "$mysql_commands"
  else
    banner "Unable to setup mariadb please check manually"
  fi
}
__copy_ssl_certs() {
  local _config_ssl_cert="$1"
  local _config_ssl_key="$2"

  if [[ -e "$SSL_CERT_PATH" ]]; then
    mv "$SSL_CERT_PATH"{,.orig}
  fi

  if [ -e "$SSL_KEY_PATH" ]; then
    mv "$SSL_KEY_PATH"{,.orig}
  fi

  if [[ -f "$(__config_get "$_config_ssl_cert")"  && -f "$(__config_get "$_config_ssl_key")" ]]; then
    cp "$(__config_get "$_config_ssl_cert")" "$SSL_CERT_PATH"
    cp "$(__config_get "$_config_ssl_key")" "$SSL_KEY_PATH"
  else
    mv "$NGINX_SITE_DIR"/passbolt_ssl.conf{,.orig}
    banner "Unable to locate SSL certificate files."
  fi
}

__setup_letsencrypt() {
  local _config_passbolt_host="$1"
  local _config_email="$2"

  certbot certonly --authenticator webroot \
    -n \
    -w "$PASSBOLT_BASE_DIR" \
    -d "$(__config_get "$_config_passbolt_host")" \
    -m "$(__config_get "$_config_email")" \
    --agree-tos
}
install_gpg_extension() {
  if [ "$(php -m |grep gnupg)" != "gnupg" ]; then
    pecl install gnupg
    echo "extension=gnupg.so" > "$PHP_EXT_DIR"/gnupg.ini
  fi
}
# require _mysql_db_installer.sh
# require helpers/utils/messages.sh
# require ../initializers/_variable_accessor.sh
# require service_enabler.sh
# require package_installer.sh
mysql_setup() {
  if [[ "$(__config_get 'mariadb_local_installation')" == true ]]; then
    banner 'Installing mariadb...'
    install_packages 'mariadb-server'
    enable_service 'mariadb'
    __install_db 'mariadb_root_password' 'mariadb_user' 'mariadb_passbolt_password' 'mariadb_name'
  else
    banner 'Using remote or custom database installation'
  fi
}
__installer_command() {
  local _installer=''
  case $OS in
    'debian')
      _installer=apt-get
      ;;
    'centos')
      _installer=yum
      ;;
    *)
      die "Unsupported OS"
      ;;
  esac

  echo "$_installer"
}


install_packages() {
  local installer
  local packages="$1"

  installer="$(__installer_command)"
  "$installer" -y install $packages
}
# require setup_composer.sh
passbolt_install() {
  local branch="$1"

  if [ -d "$PASSBOLT_BASE_DIR" ]; then
    cd "$PASSBOLT_BASE_DIR" && git pull && cd -
  else
    git clone --progress -b "$branch" "$PASSBOLT_PRO_REPO" "$PASSBOLT_BASE_DIR"
  fi
  if [ ! -f "$PASSBOLT_BASE_DIR/config/app.php" ]; then
    cp "$PASSBOLT_BASE_DIR"/config/{app.default.php,app.php}
  fi

  chown -R "$WWW_USER":"$WWW_USER" "$PASSBOLT_BASE_DIR"
  composer_install "$WWW_USER"
  chmod +w -R "$PASSBOLT_BASE_DIR/tmp"
  chmod +w "$PASSBOLT_BASE_DIR/webroot/img/public"
}
enable_service() {
  systemctl enable "$1"
  systemctl restart "$1"
}

stop_service() {
  systemctl stop "$1"
}
# require utils/messages.sh
# require utils/errors.sh
composer_check_signature() {
	EXPECTED_SIGNATURE=$(wget -q -O - https://composer.github.io/installer.sig)
	php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
	ACTUAL_SIGNATURE=$(php -r "echo hash_file('SHA384', 'composer-setup.php');")

	if [ "$EXPECTED_SIGNATURE" != "$ACTUAL_SIGNATURE" ]
	then
			rm composer-setup.php
			die 'ERROR: Invalid installer signature'
	fi
}

composer_install() {
  local www_user="$1"
  banner "Installing composer..."
	composer_check_signature
  php composer-setup.php --install-dir=/usr/bin
  php -r "unlink('composer-setup.php');"

  banner "Installing composer dependencies..."
  su -c "cd $PASSBOLT_BASE_DIR; composer.phar install -d $PASSBOLT_BASE_DIR --no-dev -o -n" -s /bin/bash "$www_user"
}
cron_job() {
  local process_email="$PASSBOLT_BASE_DIR/bin/cake EmailQueue.sender"

  if [ ! -d "$CRONTAB_DIR" ] || [ ! "$(grep "$process_email" "$CRONTAB_DIR"/* )" ]; then
    echo "* * * * * $process_email" | crontab -u "$WWW_USER" -
  fi
}
# require package_installer.sh
# require service_enabler.sh
setup_entropy(){
  if [[ "$(__config_get 'haveged_install')" == true ]]; then
    install_packages haveged
    enable_service haveged
  fi
}
# require service_enabler.sh
setup_fpm(){
  if [ -f "$FPM_WWW_POOL" ]; then
    cp "$FPM_WWW_POOL"{,.orig}
  fi

  cp "$script_directory/conf/php/www.conf" "$FPM_WWW_POOL"
  sed -i s:_WWW_USER_:"$WWW_USER": "$FPM_WWW_POOL"

  enable_service "$FPM_SERVICE"
}
setup_gpg_keyring() {
  if [ ! -d "$GNUPG_HOME" ]; then
    mkdir -p "$GNUPG_HOME"
    chown -R "$WWW_USER":"$WWW_USER" "$GNUPG_HOME"
    su -c "gpg --list-keys" -s /bin/bash "$WWW_USER"
  fi
}
# require utils/messages.sh
# require service_enabler.sh
# require _setup_ssl.sh
__nginx_config(){
  local source_template="$1"
  local nginx_config_file="$2"
  local _config_passbolt_host="$3"

  if [ ! -f "$nginx_config_file" ]; then
    cp "$source_template" "$nginx_config_file"
    sed -i s:_SERVER_NAME_:"$(__config_get "$_config_passbolt_host")": "$nginx_config_file"
  fi
}

__ssl_substitutions(){
    sed -i s:_NGINX_CERT_FILE_:"$SSL_CERT_PATH": "$NGINX_SITE_DIR/passbolt_ssl.conf"
    sed -i s:_NGINX_KEY_FILE_:"$SSL_KEY_PATH": "$NGINX_SITE_DIR/passbolt_ssl.conf"
}

setup_nginx(){
  local passbolt_domain

  passbolt_domain=$(__config_get 'passbolt_hostname')
  banner "Setting up nginx..."

  __nginx_config "$script_directory/conf/nginx/passbolt.conf" "$NGINX_SITE_DIR/passbolt.conf" 'passbolt_hostname'
  enable_service 'nginx'

  if [[ "$(__config_get 'ssl_auto')" == 'true' ]]; then
    if __setup_letsencrypt 'passbolt_hostname' 'letsencrypt_email'; then
      __nginx_config "$script_directory/conf/nginx/passbolt_ssl.conf" "$NGINX_SITE_DIR/passbolt_ssl.conf" 'passbolt_hostname'
      ln -s "$LETSENCRYPT_LIVE_DIR/$passbolt_domain/cert.pem" "$SSL_CERT_PATH"
      ln -s "$LETSENCRYPT_LIVE_DIR/$passbolt_domain/privkey.pem" "$SSL_KEY_PATH"
      __ssl_substitutions
      enable_service 'nginx'
    else
      banner "WARNING: Unable to setup SSL using lets encrypt. Please check the install.log"
    fi
  fi

  if [[ "$(__config_get 'ssl_manual')" == 'true' ]]; then
    __nginx_config "$script_directory/conf/nginx/passbolt_ssl.conf" "$NGINX_SITE_DIR/passbolt_ssl.conf" 'passbolt_hostname'
    __copy_ssl_certs 'ssl_certificate' 'ssl_privkey'
    __ssl_substitutions
    enable_service 'nginx'
  fi
}
main(){
  init_config
  get_options "$@"
  validate_os
  disclaimer
  interactive_prompter
  usermod -d "$WWW_USER_HOME" "$WWW_USER"
  banner 'Installing os dependencies...'
  install_packages "$(cat "$script_directory/conf/packages.txt")"
  mysql_setup
  setup_fpm
  setup_gpg_keyring
  passbolt_install 'master'
  setup_nginx
  setup_entropy
  cron_job
  installation_complete
}

main "$@" 2>&1 | tee -a install.log
