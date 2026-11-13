#!/usr/bin/env bash
# Install Open Source Point of Sale (OSPOS) on Ubuntu/Debian with Apache + MariaDB + PHP.
#
# Usage (as root):
#   sudo bash linux/install-ospos.sh                # use the prebuilt copy in ../offline (no build needed)
#   sudo bash linux/install-ospos.sh --from-source  # download the latest OSPOS source and build it
#
# Settings you can override with environment variables:
#   INSTALL_DIR (default /var/www/ospos)   DB_NAME (default ospos)   DB_USER (default ospos)
#   HOSTNAMES   (default localhost,127.0.0.1 - the names you will type in the browser)
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/var/www/ospos}"
DB_NAME="${DB_NAME:-ospos}"
DB_USER="${DB_USER:-ospos}"
HOSTNAMES="${HOSTNAMES:-localhost,127.0.0.1}"
FROM_SOURCE=0
[[ "${1:-}" == "--from-source" ]] && FROM_SOURCE=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
PHPV=8.3

log() { printf '\n==> %s\n' "$*"; }

if [[ $EUID -ne 0 ]]; then
    echo "Please run as root (sudo bash $0)" >&2
    exit 1
fi

if [[ -e "$INSTALL_DIR" ]]; then
    echo "$INSTALL_DIR already exists. Remove it or set INSTALL_DIR to another folder." >&2
    exit 1
fi

log "Installing Apache, MariaDB and PHP $PHPV"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq mariadb-server apache2 libapache2-mod-php$PHPV unzip openssl \
    php$PHPV-cli php$PHPV-bcmath php$PHPV-gd php$PHPV-intl php$PHPV-mbstring \
    php$PHPV-curl php$PHPV-xml php$PHPV-mysql

log "Starting MariaDB"
if pidof systemd >/dev/null 2>&1 && systemctl is-system-running >/dev/null 2>&1; then
    systemctl enable --now mariadb
else
    mkdir -p /run/mysqld && chown mysql:mysql /run/mysqld
    mariadb -e 'SELECT 1' >/dev/null 2>&1 || (mysqld_safe >/dev/null 2>&1 &)
fi
for _ in $(seq 1 30); do mariadb -e 'SELECT 1' >/dev/null 2>&1 && break; sleep 1; done
mariadb -e 'SELECT 1' >/dev/null

log "Creating database '$DB_NAME' and user '$DB_USER'"
DB_PASS="$(openssl rand -hex 16)"
mariadb <<SQL
CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';
ALTER USER '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';
GRANT ALL ON \`$DB_NAME\`.* TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
SQL

mkdir -p "$(dirname "$INSTALL_DIR")"
if [[ $FROM_SOURCE -eq 1 ]]; then
    log "Downloading and building OSPOS from source (needs git, composer and Node.js 22+)"
    git clone --depth 1 https://github.com/opensourcepos/opensourcepos.git "$INSTALL_DIR"
    cd "$INSTALL_DIR"
    # Ubuntu's PHP keeps a low version number even though security fixes are backported,
    # so only the PHP version check is skipped; extension checks still apply.
    composer install --no-dev --optimize-autoloader --no-interaction --ignore-platform-req=php
    npm install --no-audit --no-fund
    npm run build
else
    ZIP="$(ls "$REPO_ROOT"/offline/ospos-*-prebuilt.zip 2>/dev/null | sort | tail -n 1 || true)"
    if [[ -z "$ZIP" ]]; then
        echo "No prebuilt zip found in $REPO_ROOT/offline. Use --from-source instead." >&2
        exit 1
    fi
    log "Unpacking $(basename "$ZIP")"
    TMP="$(mktemp -d)"
    unzip -q "$ZIP" -d "$TMP"
    mv "$TMP/ospos" "$INSTALL_DIR"
    rmdir "$TMP"
fi

log "Writing $INSTALL_DIR/.env"
cd "$INSTALL_DIR"
cp .env.example .env
sed -i \
    -e "s/^CI_ENVIRONMENT=.*/CI_ENVIRONMENT=production/" \
    -e "s/^app.allowedHostnames=.*/app.allowedHostnames='$HOSTNAMES'/" \
    -e "s/^database.default.database=.*/database.default.database='$DB_NAME'/" \
    -e "s/^database.default.username=.*/database.default.username='$DB_USER'/" \
    -e "s/^database.default.password=.*/database.default.password='$DB_PASS'/" \
    .env
chmod 640 .env
# The app writes its own encryption keys into .env on first run, so the web server must own it.
chown www-data:www-data "$INSTALL_DIR" .env
chown -R www-data:www-data writable public

log "Configuring Apache"
cat > /etc/apache2/sites-available/ospos.conf <<EOF
<VirtualHost *:80>
    ServerName localhost
    DocumentRoot $INSTALL_DIR/public
    <Directory $INSTALL_DIR/public>
        AllowOverride All
        Require all granted
    </Directory>
    ErrorLog \${APACHE_LOG_DIR}/ospos_error.log
    CustomLog \${APACHE_LOG_DIR}/ospos_access.log combined
</VirtualHost>
EOF
a2dissite -q 000-default >/dev/null 2>&1 || true
a2ensite -q ospos
a2enmod -q rewrite
apache2ctl configtest
if pidof systemd >/dev/null 2>&1 && systemctl is-system-running >/dev/null 2>&1; then
    systemctl enable apache2 && systemctl restart apache2
else
    apache2ctl -k restart 2>/dev/null || apache2ctl start
fi

CRED=/root/ospos-credentials.txt
cat > "$CRED" <<EOF
OSPOS install folder : $INSTALL_DIR
Database name        : $DB_NAME
Database user        : $DB_USER
Database password    : $DB_PASS
OSPOS login          : admin / pointofsale  (change this after first login)
EOF
chmod 600 "$CRED"

log "Done"
cat <<EOF
Open http://localhost/ in a browser.
  1. On first visit click "Initialize" to create the database tables.
  2. Log in with username admin and password pointofsale, then change the password.
Database credentials were saved to $CRED
EOF
