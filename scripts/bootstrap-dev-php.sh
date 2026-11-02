#!/usr/bin/env bash
# Install PHP development tooling for the isolated dev account. phpMyAdmin is
# intentionally bound to loopback and published only through Tailscale Serve.
set -Eeuo pipefail

DEV_USER="${DEV_USER:-dev}"
DEV_HOME="/home/${DEV_USER}"
PMA_PORT="${PMA_PORT:-8089}"
APACHE_LISTEN_CONF="/etc/apache2/conf-available/phpmyadmin-dev-listen.conf"
APACHE_SITE="/etc/apache2/sites-available/phpmyadmin-dev.conf"

if [[ $EUID -ne 0 ]]; then
    echo "Run with sudo: sudo $0"
    exit 1
fi

if ! id "$DEV_USER" >/dev/null 2>&1; then
    echo "Missing development user: run bootstrap-dev-workspace.sh first."
    exit 1
fi

if ! systemctl is-active --quiet mariadb; then
    echo "MariaDB is not running. Start it before configuring phpMyAdmin."
    exit 1
fi

read -r -s -p "Password for MariaDB user admin: " PMA_ADMIN_PASSWORD
echo
if [[ -z "$PMA_ADMIN_PASSWORD" ]]; then
    echo "A non-empty MariaDB password is required."
    exit 1
fi

# phpMyAdmin is installed without its default Apache integration so it cannot
# accidentally appear on the existing LAN-facing Apache listener.
export DEBIAN_FRONTEND=noninteractive
echo "phpmyadmin phpmyadmin/dbconfig-install boolean false" | debconf-set-selections
echo "phpmyadmin phpmyadmin/reconfigure-webserver multiselect none" | debconf-set-selections
apt-get update
apt-get install -y --no-install-recommends phpmyadmin php-mbstring php-zip php-gd php-curl

a2disconf phpmyadmin >/dev/null 2>&1 || true

cat >"$APACHE_LISTEN_CONF" <<EOF
# Local-only phpMyAdmin listener. Tailscale Serve is the sole remote access path.
Listen 127.0.0.1:${PMA_PORT}
EOF

cat >"$APACHE_SITE" <<EOF
<VirtualHost 127.0.0.1:${PMA_PORT}>
    ServerName localhost
    DocumentRoot /usr/share/phpmyadmin
    Alias / /usr/share/phpmyadmin/

    <Directory /usr/share/phpmyadmin>
        Options SymLinksIfOwnerMatch
        DirectoryIndex index.php
        Require all granted
    </Directory>

    # Scope large imports to phpMyAdmin's private development endpoint.
    # post_max_size leaves multipart overhead above the 900 MB file limit.
    php_admin_value upload_max_filesize 900M
    php_admin_value post_max_size 920M
    php_admin_value memory_limit 1024M
    php_admin_value max_execution_time 900
    php_admin_value max_input_time 900

    ErrorLog \${APACHE_LOG_DIR}/phpmyadmin-dev-error.log
    CustomLog \${APACHE_LOG_DIR}/phpmyadmin-dev-access.log combined
</VirtualHost>
EOF

a2enconf phpmyadmin-dev-listen >/dev/null
a2ensite phpmyadmin-dev >/dev/null
apachectl configtest
systemctl reload apache2

# The account authenticates only locally because MariaDB itself listens on
# loopback. The password is read interactively and never written to this repo.
sql_password="${PMA_ADMIN_PASSWORD//\'/\'\'}"
mariadb --protocol=socket --user=root <<EOF
CREATE USER IF NOT EXISTS 'admin'@'localhost' IDENTIFIED BY '${sql_password}';
ALTER USER 'admin'@'localhost' IDENTIFIED BY '${sql_password}';
GRANT ALL PRIVILEGES ON *.* TO 'admin'@'localhost' WITH GRANT OPTION;
FLUSH PRIVILEGES;
EOF
unset PMA_ADMIN_PASSWORD sql_password

# Install the official standalone binary through a fresh temporary directory.
# This remains idempotent even if a previous installer run left files in dev's
# home directory.
case "$(uname -m)" in
    x86_64) symfony_arch='amd64' ;;
    aarch64) symfony_arch='arm64' ;;
    *)
        echo "Unsupported Symfony CLI architecture: $(uname -m)"
        exit 1
        ;;
esac
symfony_tmp="$(mktemp -d)"
trap 'rm -rf -- "$symfony_tmp"' EXIT
curl -fsSL --proto '=https' --tlsv1.2 \
    "https://github.com/symfony-cli/symfony-cli/releases/latest/download/symfony-cli_linux_${symfony_arch}.tar.gz" \
    | tar -xzf - -C "$symfony_tmp"
install -o root -g root -m 0755 "$symfony_tmp/symfony" /usr/local/bin/symfony

tailscale serve --https="$PMA_PORT" --bg --yes "http://127.0.0.1:${PMA_PORT}"

echo
echo "Symfony CLI: $(symfony version)"
echo "phpMyAdmin is available only within the tailnet at:"
echo "https://$(tailscale status --json | php -r '$j=json_decode(stream_get_contents(STDIN), true); echo $j["Self"]["DNSName"];'):${PMA_PORT}/"
echo "MariaDB user created: admin@localhost"
echo "Database listener: 127.0.0.1:3306 (not LAN or Internet)"
tailscale serve status
