#!/usr/bin/env bash
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
    echo "Run as root." >&2
    exit 1
fi


print_step() { echo; echo ">>> $1"; }

confirm() {
    if [[ "${AUTO_YES:-0}" == "1" ]]; then return 0; fi
    read -rp "$1 [y/N] " ans
    [[ "${ans,,}" == "y" ]]
}


print_step "Stopping and disabling Pterodactyl services"

for svc in pteroq wings; do
    if systemctl list-units --full -all 2>/dev/null | grep -q "${svc}.service"; then
        systemctl stop "${svc}" 2>/dev/null || true
        systemctl disable "${svc}" 2>/dev/null || true
        rm -f "/etc/systemd/system/${svc}.service"
    fi
done

systemctl daemon-reload 2>/dev/null || true


print_step "Removing panel files"

rm -rf /var/www/pterodactyl


print_step "Removing Wings binary and config"

rm -rf /etc/pterodactyl
rm -f /usr/local/bin/wings
rm -rf /var/lib/pterodactyl


print_step "Removing crontab entry for www-data"

if crontab -u www-data -l 2>/dev/null | grep -q "artisan"; then
    crontab -u www-data -l 2>/dev/null \
        | grep -v "artisan" \
        | crontab -u www-data - 2>/dev/null || true
fi


print_step "Dropping MariaDB/MySQL database and user"

if command -v mariadb &>/dev/null || command -v mysql &>/dev/null; then
    DB_CMD="mariadb"
    command -v mariadb &>/dev/null || DB_CMD="mysql"

    "${DB_CMD}" -u root 2>/dev/null <<'SQL' || true
DROP DATABASE IF EXISTS panel;
DROP DATABASE IF EXISTS pterodactyl;
DROP USER IF EXISTS 'pterodactyl'@'127.0.0.1';
DROP USER IF EXISTS 'pterodactyl'@'localhost';
FLUSH PRIVILEGES;
SQL
fi


print_step "Removing Nginx pterodactyl site config"

rm -f /etc/nginx/sites-enabled/pterodactyl.conf
rm -f /etc/nginx/sites-enabled/pterodactyl
rm -f /etc/nginx/sites-available/pterodactyl.conf
rm -f /etc/nginx/sites-available/pterodactyl
rm -f /var/log/nginx/pterodactyl.app-error.log

if [[ -f /etc/nginx/sites-available/default ]] \
   && [[ ! -f /etc/nginx/sites-enabled/default ]]; then
    ln -sf /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default
fi

if systemctl is-active --quiet nginx 2>/dev/null; then
    nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null || true
fi


print_step "Removing Let's Encrypt / Certbot data"

if [[ -d /etc/letsencrypt/live ]]; then
    for cert_dir in /etc/letsencrypt/live/*/; do
        cert_name=$(basename "${cert_dir}")
        if confirm "Remove Let's Encrypt cert '${cert_name}'?"; then
            certbot delete --cert-name "${cert_name}" 2>/dev/null || true
        fi
    done
fi


print_step "Removing Docker (installed by Wings)"

if confirm "Remove Docker engine and all containers/images?"; then
    docker rm -f "$(docker ps -aq)" 2>/dev/null || true
    docker system prune -af --volumes 2>/dev/null || true

    systemctl stop docker docker.socket 2>/dev/null || true
    systemctl disable docker docker.socket 2>/dev/null || true

    apt-get purge -y \
        docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin \
        docker-ce-rootless-extras 2>/dev/null || true

    rm -rf /var/lib/docker /etc/docker
    rm -f /usr/local/bin/docker-compose
fi


print_step "Removing PHP (all versions installed by panel installer)"

if confirm "Remove all PHP packages installed by pterodactyl?"; then
    systemctl stop "php*-fpm" 2>/dev/null || true

    PHPLIST=$(dpkg -l 'php*' 2>/dev/null | awk '/^ii/{print $2}' | tr '\n' ' ')
    if [[ -n "${PHPLIST}" ]]; then
        # shellcheck disable=SC2086
        apt-get purge -y ${PHPLIST} 2>/dev/null || true
    fi
fi


print_step "Removing MariaDB"

if confirm "Remove MariaDB server?"; then
    systemctl stop mariadb 2>/dev/null || true
    apt-get purge -y mariadb-server mariadb-client mariadb-common \
        'mariadb-server-*' 'mariadb-client-*' 2>/dev/null || true
    rm -rf /var/lib/mysql /etc/mysql
fi


print_step "Removing Redis"

if confirm "Remove Redis server?"; then
    systemctl stop redis-server 2>/dev/null || true
    apt-get purge -y redis-server redis-tools 2>/dev/null || true
    rm -rf /etc/redis /var/lib/redis
fi


print_step "Removing Nginx"

if confirm "Remove Nginx?"; then
    systemctl stop nginx 2>/dev/null || true
    apt-get purge -y nginx nginx-common nginx-full nginx-core 2>/dev/null || true
    rm -rf /etc/nginx /var/log/nginx
fi


print_step "Removing Composer"

rm -f /usr/local/bin/composer


print_step "Removing third-party APT repositories added by installer"

rm -f /etc/apt/sources.list.d/redis.list
rm -f /etc/apt/sources.list.d/mariadb.list
rm -f /etc/apt/sources.list.d/docker.list
rm -f /etc/apt/sources.list.d/php.list
rm -f /etc/apt/sources.list.d/ondrej-*.list

find /etc/apt/sources.list.d/ -name '*ondrej*' -delete 2>/dev/null || true
find /etc/apt/sources.list.d/ -name '*mariadb*' -delete 2>/dev/null || true
find /etc/apt/sources.list.d/ -name '*redis*' -delete 2>/dev/null || true
find /etc/apt/sources.list.d/ -name '*docker*' -delete 2>/dev/null || true

rm -f /usr/share/keyrings/redis-archive-keyring.gpg
rm -f /usr/share/keyrings/docker-archive-keyring.gpg
rm -f /etc/apt/keyrings/docker.gpg
rm -f /usr/share/keyrings/mariadb-keyring.pgp

find /usr/share/keyrings/ -name '*mariadb*' -delete 2>/dev/null || true
find /usr/share/keyrings/ -name '*docker*' -delete 2>/dev/null || true
find /usr/share/keyrings/ -name '*ondrej*' -delete 2>/dev/null || true
find /etc/apt/keyrings/ -name '*docker*' -delete 2>/dev/null || true


print_step "Removing UFW rules added by installer"

if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active"; then
    if confirm "Remove UFW rules for ports 80, 443, 8080, 2022?"; then
        ufw delete allow 80/tcp 2>/dev/null || true
        ufw delete allow 443/tcp 2>/dev/null || true
        ufw delete allow 8080/tcp 2>/dev/null || true
        ufw delete allow 2022/tcp 2>/dev/null || true
        ufw reload 2>/dev/null || true
    fi
fi


print_step "Running apt autoremove and clean"

apt-get autoremove -y 2>/dev/null || true
apt-get autoclean -y 2>/dev/null || true
apt-get update 2>/dev/null || true


echo
echo "Done. Pterodactyl and all related components have been removed."
echo "Review /etc/apt/sources.list.d/ manually if you added other custom repos."
