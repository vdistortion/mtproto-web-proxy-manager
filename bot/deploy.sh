#!/usr/bin/env bash
set -euo pipefail

# The repository lives here; the Compose application is in its bot/ subdirectory.
directory="${BOT_INSTALL_DIR:-$HOME/projects/mtproxy-manager-bot}"
repository="${BOT_REPOSITORY:-https://github.com/vdistortion/mtproto-web-proxy-manager.git}"
branch="${BOT_BRANCH:-main}"
action="${1:-install}"

case "$action" in
    prepare|install|configure|update|start|stop|restart|status|logs|uninstall|purge) ;;
    *) echo 'Usage: bash deploy.sh [prepare|install|configure|update|start|stop|restart|status|logs|uninstall|purge]' >&2; exit 1 ;;
esac

[[ "$directory" == /* && "$directory" != / ]] || { echo 'BOT_INSTALL_DIR must be an absolute directory.' >&2; exit 1; }

for command in git docker flock; do
    command -v "$command" >/dev/null || { echo "Required: $command" >&2; exit 1; }
done
docker compose version >/dev/null
docker info >/dev/null
mkdir -p "$(dirname "$directory")"
exec 9>"${directory}.deploy.lock"
flock -n 9 || { echo 'Another deployment is running.' >&2; exit 1; }

if [[ ! -d "$directory/.git" ]]; then
    [[ "$action" == install || "$action" == prepare ]] || { echo "Not installed: $directory" >&2; exit 1; }
    git clone --branch "$branch" --single-branch "$repository" "$directory"
fi

cd "$directory"
if [[ "$action" == install || "$action" == update || "$action" == prepare ]]; then
[[ "$(git branch --show-current)" == "$branch" ]] || {
    echo "Expected branch: $branch. Set BOT_BRANCH for a different branch." >&2; exit 1;
}
[[ -z "$(git status --porcelain --untracked-files=normal)" ]] || {
    echo 'Working tree has local changes. Commit or move them before updating.' >&2; exit 1;
}
git fetch origin "$branch"
git merge --ff-only "origin/$branch"
fi

cd bot
if [[ "$action" == configure ]]; then
    # Read only literal values written by this installer; never source an env file.
    value() { if [[ -f .env ]]; then awk -F= -v key="$1" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' .env; fi; }
    old_token=$(value VK_TOKEN)
    old_group=$(value VK_GROUP_ID)
    old_admins=$(value VK_ADMIN_IDS)
    read -rsp 'VK token (Enter — сохранить существующий): ' token; echo
    token="${token:-$old_token}"
    read -rp "VK group ID [$old_group]: " group
    group="${group:-$old_group}"
    read -rp "VK admin IDs через запятую [$old_admins]: " admins
    admins="${admins:-$old_admins}"
    proxy_directory="${BOT_PROXY_CONFIG_DIR:-$(value PROXY_CONFIG_DIR)}"
    proxy_directory="${proxy_directory:-/etc/mtproto-manager}"
    proxy_directory="${proxy_directory#\"}"
    proxy_directory="${proxy_directory%\"}"
    [[ "$token" =~ ^[A-Za-z0-9_.-]+$ && "$group" =~ ^[1-9][0-9]*$ && "$admins" =~ ^[1-9][0-9]*(,[1-9][0-9]*)*$ ]] || {
        echo 'Некорректный токен или числовые VK ID; настройки сохранены без изменений.' >&2; exit 1;
    }
    [[ "$proxy_directory" == /* && "$proxy_directory" != *[\$\'\"\\]* && "$proxy_directory" != *$'\n'* ]] || {
        echo 'Некорректный путь конфигурации прокси.' >&2; exit 1;
    }
    (umask 077; printf 'VK_TOKEN=%s\nVK_GROUP_ID=%s\nVK_ADMIN_IDS=%s\nPROXY_CONFIG_DIR="%s"\nBOT_DATA_DIR=./data\n' \
        "$token" "$group" "$admins" "$proxy_directory" > .env.tmp)
    mv .env.tmp .env
    docker compose up -d --build --wait --wait-timeout 60
    exit
fi
case "$action" in
    status) docker compose ps -a; exit ;;
    logs) docker compose logs --tail=100 bot; exit ;;
    stop) docker compose stop bot; exit ;;
    restart) docker compose restart bot; exit ;;
    start) docker compose up -d --wait --wait-timeout 60; exit ;;
    uninstall) docker compose down --remove-orphans; exit ;;
    purge)
        docker compose down --remove-orphans --volumes
        rm -f .env
        exit ;;
esac
if [[ ! -f .env ]]; then
    (umask 077; cp .env.example .env)
    echo "Fill in $directory/bot/.env, then run:"
    echo "bash $directory/bot/deploy.sh install"
    exit 0
fi
[[ "$action" != prepare ]] || exit 0

docker compose config --quiet
# Build first: a failed build leaves the running container intact.
docker compose build --pull
docker compose up -d --wait --wait-timeout 60
echo "Bot deployed to $directory/bot"
