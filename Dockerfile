# Znuny LTS Docker image (web + application layer)
# Dynamically fetches the latest Znuny LTS (major series defined by ZNUNY_LTS_MAJOR) at build time unless a specific version is supplied.
# It expects an external MariaDB/MySQL database provided via docker-compose (see accompanying docker-compose.yml)

FROM debian:12-slim

ENV ZNUNY_HOME=/opt/znuny \
  ZNUNY_USER=otrs \
  ZNUNY_GROUP=otrs

# Build arguments:
#   ZNUNY_VERSION   - explicit version (e.g., 6.5.15). Use "latest" to auto-detect newest for LTS major.
#   ZNUNY_LTS_MAJOR - major.minor LTS track (default 6.5)
ARG ZNUNY_VERSION=latest
ARG ZNUNY_LTS_MAJOR=6.5

# Install base OS deps and Perl/Apache modules frequently required by Znuny.
# (List derived from official installation docs; trim or extend as needed.)
RUN set -eux; \
    apt-get update; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      apache2 \
      libapache2-mod-perl2 libdbd-mysql-perl libtimedate-perl libnet-dns-perl \
      libnet-ldap-perl libio-socket-ssl-perl libpdf-api2-perl libsoap-lite-perl \
      libtext-csv-xs-perl libjson-xs-perl libapache-dbi-perl libxml-libxml-perl \
      libxml-libxslt-perl libyaml-perl libarchive-zip-perl libcrypt-eksblowfish-perl \
      libencode-hanextra-perl libmail-imapclient-perl libtemplate-perl libdatetime-perl \
      libmoo-perl bash-completion libyaml-libyaml-perl libjavascript-minifier-xs-perl \
      libcss-minifier-xs-perl libauthen-sasl-perl libauthen-ntlm-perl libhash-merge-perl \
      libical-parser-perl libspreadsheet-xlsx-perl libdata-uuid-perl \
      mariadb-client \
      cron \
      curl ca-certificates \
      locales \
      perl perl-modules \
      jq; \
    rm -rf /var/lib/apt/lists/*; \
    echo "en_US.UTF-8 UTF-8" > /etc/locale.gen && locale-gen

# Create znuny user and group
RUN set -eux; \
    groupadd --system ${ZNUNY_GROUP}; \
    useradd --system --home ${ZNUNY_HOME} --gid ${ZNUNY_GROUP} -g www-data --shell /bin/bash -M -N ${ZNUNY_USER};

# Download and extract Znuny (latest matching LTS major if ZNUNY_VERSION=latest)
RUN set -eux; \
  # Ensure target does not pre-exist so mv will rename instead of nesting
  rm -rf ${ZNUNY_HOME}; \
  if [ "${ZNUNY_VERSION}" = "latest" ]; then \
    echo "Resolving latest Znuny ${ZNUNY_LTS_MAJOR}.x version"; \
    # Try GitHub API first (jq path)
    if command -v jq >/dev/null 2>&1; then \
      ZNUNY_VERSION=$(curl -fsSL -H 'Accept: application/vnd.github+json' "https://api.github.com/repos/znuny/Znuny/tags?per_page=200" 2>/dev/null \
        | jq -r '.[].name' \
        | sed -E 's/^rel-([0-9]+)_([0-9]+)_([0-9]+)/\1.\2.\3/' \
        | sed -E 's/^v//' \
        | grep -E "^${ZNUNY_LTS_MAJOR}\\.[0-9]+$" \
        | sort -V \
        | tail -1); \
    fi; \
    # Fallback without jq (grep JSON)
    if [ -z "${ZNUNY_VERSION}" ]; then \
      echo "GitHub jq method failed, trying grep parse"; \
      ZNUNY_VERSION=$(curl -fsSL -H 'Accept: application/vnd.github+json' "https://api.github.com/repos/znuny/Znuny/tags?per_page=200" 2>/dev/null \
        | grep -oE '"name" *: *"(rel-[0-9_]+|v?[0-9]+\.[0-9]+\.[0-9]+)"' \
        | sed -E 's/.*"name" *: *"//' \
        | sed -E 's/"$//' \
        | sed -E 's/^rel-([0-9]+)_([0-9]+)_([0-9]+)/\1.\2.\3/' \
        | sed -E 's/^v//' \
        | grep -E "^${ZNUNY_LTS_MAJOR}\\.[0-9]+$" \
        | sort -V \
        | tail -1); \
    fi; \
    # Fallback to scraping download site
    if [ -z "${ZNUNY_VERSION}" ]; then \
      echo "Falling back to download.znuny.org scraping"; \
      ZNUNY_VERSION=$(curl -fsSL https://download.znuny.org/releases/ 2>/dev/null \
        | grep -oE "znuny-${ZNUNY_LTS_MAJOR}\\.[0-9]+" \
        | sed -E 's/znuny-//' \
        | sort -V \
        | tail -1); \
    fi; \
    if [ -z "$ZNUNY_VERSION" ]; then echo "Failed to determine latest version for ${ZNUNY_LTS_MAJOR}" >&2; exit 1; fi; \
  fi; \
  echo "Using Znuny version: ${ZNUNY_VERSION}"; \
  if ! curl -fsSLo /tmp/znuny.tar.gz "https://download.znuny.org/releases/znuny-${ZNUNY_VERSION}.tar.gz"; then \
    echo "Primary download failed, trying GitHub tarball"; \
    curl -fsSLo /tmp/znuny.tar.gz "https://github.com/znuny/Znuny/archive/refs/tags/v${ZNUNY_VERSION}.tar.gz"; \
  fi; \
  dir=$(tar -tzf /tmp/znuny.tar.gz | head -1 | cut -d/ -f1); \
  tar -xzf /tmp/znuny.tar.gz -C /opt; \
  mv "/opt/${dir}" "${ZNUNY_HOME}"; \
  rm /tmp/znuny.tar.gz; \
  ln -snf ${ZNUNY_HOME} /opt/otrs || true; \
  ln -snf ${ZNUNY_HOME}/scripts/apache2-httpd.include.conf /etc/apache2/conf-available/znuny.conf || true; \ 
  cp /opt/otrs/Kernel/Config.pm.dist /opt/otrs/Kernel/Config.pm; \
  /opt/otrs/bin/otrs.SetPermissions.pl || true; \ 
  su - otrs -c \
"cd ${ZNUNY_HOME}/var/cron && for foo in *.dist; do cp \$foo \`basename \$foo .dist\`; done" || true;

# Apache modules (vhosts generated at runtime)
RUN set -eux; \
  a2dismod mpm_event || true; \
  a2enmod mpm_prefork headers filter perl lbmethod_byrequests || true; \
  a2dissite 000-default.conf || true; \
  a2enconf znuny || true

# Generate a self-signed certificate if custom one not mounted
RUN set -eux; \
    mkdir -p /etc/ssl/znuny; \
    if [ ! -f /etc/ssl/znuny/selfsigned.crt ]; then \
      openssl req -x509 -nodes -newkey rsa:2048 -days 365 \
        -subj "/CN=localhost" \
        -keyout /etc/ssl/znuny/selfsigned.key \
        -out /etc/ssl/znuny/selfsigned.crt; \
      cp /etc/ssl/znuny/selfsigned.crt /etc/ssl/znuny/chain.pem; \
    fi; \
    chmod 600 /etc/ssl/znuny/selfsigned.key

# Provide entrypoint & helper
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

WORKDIR ${ZNUNY_HOME}

# Expose HTTP/HTTPS ports
EXPOSE 80 443

# Healthcheck: simple HTTP GET
HEALTHCHECK --interval=30s --timeout=5s --start-period=40s --retries=5 CMD curl -fsS http://localhost/otrs/index.pl || exit 1

# Environment (DB vars consumed by entrypoint and initial configuration script)
ENV ZNUNY_DB_HOST=db \
  ZNUNY_DB_PORT=3306 \
  ZNUNY_DB_NAME=znuny \
  ZNUNY_DB_USER=znuny \
  ZNUNY_DB_PASSWORD=znuny \
  ZNUNY_FQDN=localhost \
  ZNUNY_SSL_CERT_FILE=/etc/ssl/znuny/selfsigned.crt \
  ZNUNY_SSL_KEY_FILE=/etc/ssl/znuny/selfsigned.key \
  ZNUNY_SSL_CHAIN_FILE=/etc/ssl/znuny/chain.pem \
  ZNUNY_ENABLE_SSL=1 \
  ZNUNY_FORCE_SSL=1 \
  ZNUNY_DEBUG=1

VOLUME ["/opt/znuny/var", "/opt/znuny/Kernel/Config"]

USER root
ENTRYPOINT ["/entrypoint.sh"]
CMD ["apache2ctl", "-D", "FOREGROUND"]
