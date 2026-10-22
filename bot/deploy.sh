#!/usr/bin/env bash
set -euo pipefail

# The repository lives here; the Compose application is in its bot/ subdirectory.
directory="${BOT_INSTALL_DIR:-$HOME/projects/mtproxy-manager-bot}"
repository="${BOT_REPOSITORY:-https://github.com/vdistortion/mtproto-web-proxy-manager.git}"
branch="${BOT_BRANCH:-main}"
action="${1:-install}"

case "$action" in
    install|update) ;;
    *) echo 'Usage: bash deploy.sh [install|update]' >&2; exit 1 ;;
esac

for command in git docker flock; do
    command -v "$command" >/dev/null || { echo "Required: $command" >&2; exit 1; }
done
docker compose version >/dev/null
docker info >/dev/null
mkdir -p "$(dirname "$directory")"
exec 9>"${directory}.deploy.lock"
flock -n 9 || { echo 'Another deployment is running.' >&2; exit 1; }

if [[ ! -d "$directory/.git" ]]; then
    [[ "$action" == install ]] || { echo "Not installed: $directory" >&2; exit 1; }
    git clone --branch "$branch" --single-branch "$repository" "$directory"
fi

cd "$directory"
[[ "$(git branch --show-current)" == "$branch" ]] || {
    echo "Expected branch: $branch. Set BOT_BRANCH for a different branch." >&2; exit 1;
}
[[ -z "$(git status --porcelain --untracked-files=normal)" ]] || {
    echo 'Working tree has local changes. Commit or move them before updating.' >&2; exit 1;
}
git fetch origin "$branch"
git merge --ff-only "origin/$branch"

cd bot
if [[ ! -f .env ]]; then
    (umask 077; cp .env.example .env)
    echo "Fill in $directory/bot/.env, then run:"
    echo "bash $directory/bot/deploy.sh install"
    exit 0
fi

docker compose config --quiet
# Build first: a failed build leaves the running container intact.
docker compose build --pull
docker compose up -d --wait --wait-timeout 60
echo "Bot deployed to $directory/bot"
