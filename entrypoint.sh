#!/usr/bin/env bash
set -euo pipefail

# Lots of inspiration could be had from https://github.com/juanluisbaptiste/docker-otrs/tree/master/otrs


# Basic initialization for Znuny inside container
ZNUNY_HOME=${ZNUNY_HOME:-/opt/znuny}
CONFIG_DIR="${ZNUNY_HOME}/Kernel"
SITE_CONFIG_DIR="${ZNUNY_HOME}/Kernel/Config"
DB_HOST=${ZNUNY_DB_HOST:-db}
DB_PORT=${ZNUNY_DB_PORT:-3306}
DB_NAME=${ZNUNY_DB_NAME:-znuny}
DB_USER=${ZNUNY_DB_USER:-znuny}
DB_PASSWORD=${ZNUNY_DB_PASSWORD:-znuny}

## Layout now normalized at build time

# Wait for DB
wait_for_db() {
  echo "[entrypoint] Waiting for database ${DB_HOST}:${DB_PORT}..." >&2
  for i in {1..60}; do
    if timeout 2 bash -c "/usr/bin/mariadb -h ${DB_HOST} -P ${DB_PORT} -u${DB_USER} -p${DB_PASSWORD} ${DB_NAME} -e 'SELECT 1'" >/dev/null 2>&1; then
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
  if ! /usr/bin/mariadb -h "${DB_HOST}" -P "${DB_PORT}" -u"${DB_USER}" -p"${DB_PASSWORD}" "${DB_NAME}" -e "SELECT id FROM users LIMIT 1" >/dev/null 2>&1; then
    echo "[entrypoint] Loading initial schema..." >&2
    mysql_cmd=(/usr/bin/mariadb -h "${DB_HOST}" -P "${DB_PORT}" -u"${DB_USER}" -p"${DB_PASSWORD}" "${DB_NAME}")
    # Schema
    if [ -f "${ZNUNY_HOME}/scripts/database/otrs-schema.mysql.sql" ]; then
      "${mysql_cmd[@]}" < "${ZNUNY_HOME}/scripts/database/otrs-schema.mysql.sql"
    fi
    if [ -f "${ZNUNY_HOME}/scripts/database/otrs-initial_insert.mysql.sql" ]; then
      "${mysql_cmd[@]}" < "${ZNUNY_HOME}/scripts/database/otrs-initial_insert.mysql.sql"
    fi
    if [ -f "${ZNUNY_HOME}/scripts/database/otrs-schema-post.mysql.sql" ]; then
      "${mysql_cmd[@]}" < "${ZNUNY_HOME}/scripts/database/otrs-schema-post.mysql.sql"
    fi
    echo "[entrypoint] Database initialized." >&2
  else
    echo "[entrypoint] Database already initialized." >&2
  fi
}

generate_vhosts() {
  local fqdn="${ZNUNY_FQDN:-localhost}"
  local enable_ssl="${ZNUNY_ENABLE_SSL:-1}"
  local force_ssl="${ZNUNY_FORCE_SSL:-1}"
  echo "[entrypoint] Generating Apache vhost configuration (FQDN=${fqdn}, SSL=${enable_ssl}, FORCE_SSL=${force_ssl})" >&2

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
  fi
}

setup_crontab() {
  echo "[entrypoint] Setting up Znuny cron jobs..." >&2
  su - ${ZNUNY_USER} -c "${ZNUNY_HOME}/bin/Cron.sh start"
}

main() {
  wait_for_db
  #init_config
  init_db
  generate_vhosts
  setup_crontab
  if [ "${ZNUNY_DEBUG:-0}" = "1" ]; then
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
  else
    exec "$@"
  fi
}

main "$@"
