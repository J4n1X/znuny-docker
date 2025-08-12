# Znuny Docker (Unofficial)

This was vibe-coded into existence until it then didn't work, so I basically created everything from on my own in the end (A great lesson can be had here - Don't rely on AI!). Not entirely working yet! As of right now, it will start up and you can access installer.pl at /otrs/installer.pl to finish the setup yourself. 

I really recommend AGAINST USING THIS right now. I really just wanted to push this up so I can pull it more easily onto the in-office server. 

Containerized setup of Znuny (former OTRS Community) with Apache + mod_perl and a MariaDB service. The image can automatically fetch the latest patch release of a given LTS major (default 6.5).

## Build & Run

By default the build resolves the newest available version in the configured LTS major (`ZNUNY_LTS_MAJOR`, default `6.5`). To pin a specific version, set `ZNUNY_VERSION` build arg (e.g. `6.5.15`).

```bash
docker compose build  # downloads latest 6.5.x unless overridden
docker compose up -d
```

Access: http://localhost:8080/otrs/index.pl (will redirect to HTTPS). HTTPS endpoint: https://localhost:8443/otrs/index.pl (self‑signed if you didn't mount your own cert).

Default admin user after initial import (from shipped initial insert) is usually `root@localhost` with password `root` (change immediately). If schema changed upstream verify credentials.

## Data Persistence
- MariaDB data: named volume `db_data`
- Znuny runtime data/logs: `znuny_var`
- Site config (Config.pm): `znuny_config`

## Customization
Edit or add Perl modules / configs by mounting additional volumes or rebuilding with required packages. For extra Perl deps, append to the `cpanm` line in the Dockerfile.

## Environment Variables (service `znuny`)
- `ZNUNY_DB_HOST` (default `db`)
- `ZNUNY_DB_PORT` (default `3306`)
- `ZNUNY_DB_NAME` (default `znuny`)
- `ZNUNY_DB_USER` (default `znuny`)
- `ZNUNY_DB_PASSWORD` (default `znuny`)
- `ZNUNY_FQDN` (default `localhost`) – used in Apache vhosts
- `ZNUNY_SSL_CERT_FILE` (default self-signed path) – mount your public cert here
- `ZNUNY_SSL_KEY_FILE` (default self-signed path)
- `ZNUNY_SSL_CHAIN_FILE` (optional chain/intermediate, defaults to self-signed cert)

To use your own certificate, mount a volume with your certs and override the variables, e.g.:

```yaml
services:
	znuny:
		environment:
			ZNUNY_FQDN: support.example.com
			ZNUNY_SSL_CERT_FILE: /certs/fullchain.pem
			ZNUNY_SSL_KEY_FILE: /certs/privkey.pem
			ZNUNY_SSL_CHAIN_FILE: /certs/chain.pem
		volumes:
			- /path/on/host/certs:/certs:ro
```

Adjust in `docker-compose.yml` accordingly.

## Upgrading
1. Stop containers
2. Backup DB + volumes
3. Rebuild with updated `ZNUNY_VERSION` or let `latest` pick up the new patch release
4. Rebuild & start
5. Run Znuny console upgrade scripts inside container if required by release notes.

## Notes
This is a simplified example; production hardening (HTTPS, proper Apache vhost, mail config, cron jobs, security updates) is still required.
