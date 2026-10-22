#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/mtproto-manager.sh"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
export TEST_DIR
BOT_STATE_FILE="$TEST_DIR/bot.conf"
CONFIG_DIR="$TEST_DIR/proxy config"
mkdir -p "$TEST_DIR/bin" "$TEST_DIR/origin/bot" "$CONFIG_DIR"
cp "$ROOT_DIR/bot/deploy.sh" "$ROOT_DIR/bot/.env.example" "$TEST_DIR/origin/bot/"
cp "$ROOT_DIR/.gitignore" "$TEST_DIR/origin/"
git -C "$TEST_DIR/origin" init -q -b main
git -C "$TEST_DIR/origin" add .
git -C "$TEST_DIR/origin" -c user.name=Test -c user.email=test@example.com commit -qm Initial
export BOT_REPOSITORY="$TEST_DIR/origin"
cat > "$TEST_DIR/bin/docker" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_DIR/docker.log"
[[ "${FAIL_DOWN:-0}" != 1 || "$*" != *'compose down'* ]]
SH
chmod +x "$TEST_DIR/bin/docker"
export PATH="$TEST_DIR/bin:$PATH"
check_root() { :; }
check_docker() { :; }
require_setup() { :; }
curl() { cp "$ROOT_DIR/bot/deploy.sh" "${@: -1}"; }
# Record the selected identity while exercising real deployment with mocked Docker.
bot_as_user() { printf '%s\n' "$BOT_OWNER" >> "$TEST_DIR/owners"; "$@"; }
export SUDO_USER="$(id -un)"
directory="$TEST_DIR/custom projects/my bot"

printf '\n%s\ntest-token\n123\n1,2\n' "$directory" | bot_install > "$TEST_DIR/install.log"
bot_load_state
[[ "$BOT_DIRECTORY" == "$directory" && "$BOT_OWNER" == "$SUDO_USER" ]]
[[ "$(stat -c %a "$BOT_STATE_FILE")" == 600 ]]
[[ "$(stat -c %a "$directory/bot/.env")" == 600 ]]
grep -q '^VK_TOKEN=test-token$' "$directory/bot/.env"
grep -Fq "PROXY_CONFIG_DIR=\"$CONFIG_DIR\"" "$directory/bot/.env"
! grep -q test-token "$TEST_DIR/install.log"
[[ "$(sort -u "$TEST_DIR/owners")" == "$SUDO_USER" ]]

# Updates preserve credentials, reject local source changes and use the saved path.
cp "$directory/bot/.env" "$TEST_DIR/env.before"
echo update > "$TEST_DIR/origin/bot/release.txt"
git -C "$TEST_DIR/origin" add .
git -C "$TEST_DIR/origin" -c user.name=Test -c user.email=test@example.com commit -qm Update
bot_command update > "$TEST_DIR/update.log"
cmp "$directory/bot/.env" "$TEST_DIR/env.before"
[[ "$(cat "$directory/bot/release.txt")" == update ]]
echo local > "$directory/bot/release.txt"
if (bot_command update) > /dev/null 2>&1; then echo 'Dirty update accepted' >&2; exit 1; fi
git -C "$directory" restore bot/release.txt

for action in status logs start stop restart; do bot_command "$action"; done
grep -q 'compose logs --tail=100 bot' "$TEST_DIR/docker.log"

# A failed container removal must preserve both credentials and registration.
if printf 'y\ny\n' | FAIL_DOWN=1 bot_uninstall > /dev/null 2>&1; then
    echo 'Failed removal accepted' >&2; exit 1
fi
cmp "$directory/bot/.env" "$TEST_DIR/env.before"
[[ -f "$BOT_STATE_FILE" ]]

printf 'y\nn\n' | bot_uninstall
cmp "$directory/bot/.env" "$TEST_DIR/env.before"
grep -qx 'compose down --remove-orphans' "$TEST_DIR/docker.log"
printf 'y\ny\n' | bot_uninstall
[[ ! -f "$directory/bot/.env" && -f "$BOT_STATE_FILE" ]]
grep -qx 'compose down --remove-orphans --volumes' "$TEST_DIR/docker.log"

# Reconfigure after purge, and reject malformed input without replacing the env file.
printf 'new-token\n123\n1\n' | bot_command configure
cp "$directory/bot/.env" "$TEST_DIR/env.before"
if printf 'bad token\n123\n1\n' | bot_command configure >/dev/null 2>&1; then
    echo 'Invalid token accepted' >&2; exit 1
fi
cmp "$directory/bot/.env" "$TEST_DIR/env.before"

# Manager update routing retains the original default and can update both components.
update_image() { echo proxy >> "$TEST_DIR/routes"; }
bot_command() { echo "bot $*" >> "$TEST_DIR/routes"; }
update_components
update_components bot
update_components all
[[ "$(cat "$TEST_DIR/routes")" == $'proxy\nbot update\nproxy\nbot update' ]]

# Failed bot removal aborts manager removal before any proxy files are touched.
(
    bot_uninstall() { return 1; }
    check_container_exists() { return 1; }
    mkdir -p "$CONFIG_DIR"
    touch "$CONFIG_DIR/must-survive"
    uninstall_script <<< y
) > "$TEST_DIR/uninstall.log" 2>&1 &
pid=$!
if wait "$pid"; then echo 'Manager removal ignored a bot error' >&2; exit 1; fi
[[ -f "$CONFIG_DIR/must-survive" ]]
echo 'Bot lifecycle tests passed.'
