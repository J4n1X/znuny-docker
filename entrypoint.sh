#!/usr/bin/env bash
set -euo pipefail

# Lots of inspiration could be had from https://github.com/juanluisbaptiste/docker-otrs/tree/master/otrs


# Basic initialization for Znuny inside container
ZNUNY_HOME=/opt/znuny
CONFIG_DIR="/opt/znuny/Kernel"
SITE_CONFIG_DIR="/opt/znuny/Kernel/Config"
DB_HOST="db"
DB_PORT=3306
DB_NAME=${MARIADB_DATABASE}
DB_USER=${MARIADB_USER}
DB_PASSWORD=${MARIADB_PASSWORD}

ZNUNY_CONFIG=/opt/znuny/Kernel/Config.pm

function add_config_value() {
  local key=${1}
  local value=${2}
  local mask=${3:-false}

  if [ "${mask}" == true ]; then
    print_value="**********"
  else
    print_value=${value}
  fi

  grep -qE \{\'\?${key}\'\?\} ${OTRS_CONFIG_FILE}
  if [ $? -eq 0 ]
  then
    print_info "Updating configuration option \e[${OTRS_ASCII_COLOR_BLUE}m${key}\e[0m with value: \e[31m${print_value}\e[0m"
    sed  -i -r "s/($Self->\{*$key*\} *= *).*/\1\"${value}\";/" ${OTRS_CONFIG_FILE}
  else
    print_info "Adding configuration option \e[${OTRS_ASCII_COLOR_BLUE}m${key}\e[0m with value: \e[31m${print_value}\e[0m"
    sed -i "/$Self->{Home} = '\/opt\/otrs';/a \
    \$Self->{'${key}'} = '${value}';" ${OTRS_CONFIG_FILE}
  fi
}

# Wait for DB
wait_for_db() {
  echo "[entrypoint] Waiting for database ${DB_HOST}:${DB_PORT}..." >&2
  for i in {1..60}; do
    if timeout 2 bash -c "/usr/bin/mariadb -h ${DB_HOST} -P ${DB_PORT} -u${MARIADB_USER} -p${MARIADB_PASSWORD} ${MARIADB_DATABASE} -e 'SELECT 1'" >/dev/null 2>&1; then
      echo "[entrypoint] Database is reachable at ${DB_HOST}:${DB_PORT}." >&2
      return 0
    fi
    sleep 2
  done
  echo "[entrypoint] ERROR: Database not reachable after timeout" >&2
  return 1
}

init_db() {
  # Run database schema if core tables missing
  if ! /usr/bin/mariadb -h "${DB_HOST}" -P "${DB_PORT}" -u"${MARIADB_USER}" -p"${MARIADB_PASSWORD}" "${MARIADB_DATABASE}" -e "SELECT id FROM users LIMIT 1" >/dev/null 2>&1; then
    echo "[entrypoint] Loading initial schema..." >&2
    mysql_cmd=(/usr/bin/mariadb -h "${DB_HOST}" -P "${DB_PORT}" -u"${MARIADB_USER}" -p"${MARIADB_PASSWORD}" "${MARIADB_DATABASE}")
    # Schema
    if [ -f "/opt/znuny/scripts/database/otrs-schema.mysql.sql" ]; then
      "${mysql_cmd[@]}" < "/opt/znuny/scripts/database/otrs-schema.mysql.sql"
    fi
    if [ -f "/opt/znuny/scripts/database/otrs-initial_insert.mysql.sql" ]; then
      "${mysql_cmd[@]}" < "/opt/znuny/scripts/database/otrs-initial_insert.mysql.sql"
    fi
    if [ -f "/opt/znuny/scripts/database/otrs-schema-post.mysql.sql" ]; then
      "${mysql_cmd[@]}" < "/opt/znuny/scripts/database/otrs-schema-post.mysql.sql"
    fi
    echo "[entrypoint] Database initialized." >&2
  else
    echo "[entrypoint] Database already initialized." >&2
  fi
}

generate_vhosts() {
  local fqdn="${WEBSERVER_FQDN}"
  local enable_ssl="${WEBSERVER_ENABLE_SSL}"
  echo "[entrypoint] Generating Apache vhost configuration (FQDN=${fqdn}, SSL=${enable_ssl})" >&2

  # Global ServerName to silence warning
  echo "ServerName ${fqdn}" > /etc/apache2/conf-available/servername.conf
  a2enconf servername >/dev/null 2>&1 || true

  cat > /etc/apache2/sites-available/znuny-http.conf <<HTTPCONF
<VirtualHost *:80>
    ServerName ${fqdn}
    DocumentRoot /opt/znuny/var/httpd/htdocs
    ScriptAlias /otrs/ /opt/znuny/bin/cgi-bin/
    Alias /otrs-web/ /opt/znuny/var/httpd/htdocs/
    # mod_perl block temporarily disabled for baseline bring-up
    <Directory /opt/znuny/bin/cgi-bin>
        Options +ExecCGI -Includes
        AllowOverride None
        Require all granted
    </Directory>
    <Directory /opt/znuny/var/httpd/htdocs>
        Options -ExecCGI -Includes
        AllowOverride None
        Require all granted
    </Directory>
    ErrorLog /proc/self/fd/2
    CustomLog /proc/self/fd/1 combined
</VirtualHost>
HTTPCONF
  a2ensite znuny-http.conf >/dev/null

  if [ "$enable_ssl" = "1" ]; then
    # Ensure self-signed exists if custom not mounted
    if [ ! -f "$ZNUNY_SSL_CERT_FILE" ] || [ ! -f "$ZNUNY_SSL_KEY_FILE" ]; then
      mkdir -p /etc/ssl/znuny
      if [ ! -f /etc/ssl/znuny/selfsigned.crt ]; then
        openssl req -x509 -nodes -newkey rsa:2048 -days 365 \
          -subj "/CN=${fqdn}" \
          -keyout /etc/ssl/znuny/selfsigned.key \
          -out /etc/ssl/znuny/selfsigned.crt >/dev/null 2>&1
        cp /etc/ssl/znuny/selfsigned.crt /etc/ssl/znuny/chain.pem || true
      fi
    fi
    cat > /etc/apache2/sites-available/znuny-https.conf <<HTTPSCONF
<IfModule mod_ssl.c>
<VirtualHost *:443>
    ServerName ${fqdn}
  DocumentRoot /opt/znuny/var/httpd/htdocs
  ScriptAlias /otrs/ /opt/znuny/bin/cgi-bin/
  Alias /otrs-web/ /opt/znuny/var/httpd/htdocs/
  # mod_perl block temporarily disabled for baseline bring-up
    <Directory /opt/znuny/bin/cgi-bin>
        Options +ExecCGI -Includes
        AllowOverride None
        Require all granted
    </Directory>
    <Directory /opt/znuny/var/httpd/htdocs>
        Options -ExecCGI -Includes
        AllowOverride None
        Require all granted
    </Directory>
    SSLEngine on
    SSLCertificateFile ${ZNUNY_SSL_CERT_FILE}
    SSLCertificateKeyFile ${ZNUNY_SSL_KEY_FILE}
$( if [ -f "$ZNUNY_SSL_CHAIN_FILE" ]; then echo "    SSLCertificateChainFile ${ZNUNY_SSL_CHAIN_FILE}"; fi )
    ErrorLog /proc/self/fd/2
    CustomLog /proc/self/fd/1 combined
</VirtualHost>
</IfModule>
HTTPSCONF
    a2ensite znuny-https.conf >/dev/null
  elif [ "$enable_ssl" = "1" ] && [ -f /etc/apache2/sites-enabled/znuny-https.conf ]; then
    echo "[entrypoint] Disabling HTTPS site configuration"
    a2dissite znuny-https.conf >/dev/null
  fi
}

setup_crontab() {
  echo "[entrypoint] Setting up Znuny cron jobs..." >&2
  su - ${ZNUNY_USER} -c "/opt/znuny/bin/Cron.sh start"
}

print_debug_info() {
  echo "[entrypoint][debug] Listing /opt/znuny top-level:" >&2
  ls -al /opt/znuny || true
  echo "[entrypoint][debug] Listing /opt/znuny/bin:" >&2
  ls -al /opt/znuny/bin || true
  echo "[entrypoint][debug] Listing /opt/znuny/bin/cgi-bin:" >&2
  ls -al /opt/znuny/bin/cgi-bin || true
  echo "[entrypoint][debug] apache2ctl -t output:" >&2
  apache2ctl -t || true
  echo "[entrypoint][debug] Dumping generated HTTP vhost config:" >&2
  sed -n '1,160p' /etc/apache2/sites-available/znuny-http.conf || true
  echo "[entrypoint][debug] Dumping generated HTTPS vhost config (if exists):" >&2
  sed -n '1,200p' /etc/apache2/sites-available/znuny-https.conf || true
  echo "[entrypoint][debug] Sleeping for inspection..." >&2
  tail -f /dev/null
}

unset_envvars() {
  echo "[entrypoint] Unsetting sensitive environment variables..." >&2
  unset MARIADB_PASSWORD MARIADB_ROOT_PASSWORD ZNUNY_ROOT_PASSWORD
  unset MARIADB_DATABASE MARIADB_USER
  unset WEBSERVER_FQDN WEBSERVER_ENABLE_HTTPS WEBSERVER_SSL_KEY_FILE
  unset WEBSERVER_SSL_CERT_FILE WEBSERVER_SSL_CHAIN_FILE
  unset ZNUNY_DEBUG ZNUNY_LANGUAGE ZNUNY_TIMEZONE ZNUNY_NUMBER_GENERATOR
  unset ZNUNY_TICKET_COUNTER ZNUNY_SENDMAIL_MODULE ZNUNY_SMTP_SERVER
  unset ZNUNY_SMTP_USER ZNUNY_SMTP_PASSWORD
}

main() {
  wait_for_db
  #init_config
  init_db

  add_config_value "DatabaseUser" ${MARIADB_USER}
  add_config_value "DatabasePw" ${MARIADB_PASSWORD} true
  add_config_value "DatabaseHost" ${DB_HOST}
  add_config_value "DatabasePort" ${DP_PORT}
  add_config_value "Database" ${MARIADB_DATABASE}

  add_config_value "SendmailModule" "Kernel::System::Email::${ZNUNY_SENDMAIL_MODULE}"
  add_config_value "SendmailModule::Host" "${ZNUNY_SMTP_SERVER}"
  add_config_value "SendmailModule::Port" "${ZNUNY_SMTP_PORT}"
  add_config_value "SendmailModule::AuthUser" "${ZNUNY_SMTP_USER}"
  add_config_value "SendmailModule::AuthPassword" "${ZNUNY_SMTP_PASSWORD}" true
  add_config_value "SecureMode" "1"

  add_config_value "Ticket::NumberGenerator" "Kernel::System::Ticket::Number::${ZNUNY_NUMBER_GENERATOR}"
  echo "${ZNUNY_TICKET_COUNTER}" > ${OTRS_ROOT}var/log/TicketCounter.log

  generate_vhosts
  setup_crontab

  if [ "${ZNUNY_DEBUG:-0}" = "1" ]; then
    print_debug_info
    unset_envvars
  else
    unset_envvars
    exec "$@"
  fi
}

main "$@"
