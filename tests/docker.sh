#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/mtproto-manager.sh"
check_docker

CONTAINER_NAME="mtproto-manager-test-$$"
CADDY_NETWORK="${CONTAINER_NAME}-net"
export COMPOSE_PROJECT_NAME="$CONTAINER_NAME"
if check_container_exists || docker network inspect "$CADDY_NETWORK" >/dev/null 2>&1; then
    echo "Тестовые имена уже заняты; существующие ресурсы не трогаю." >&2
    exit 1
fi

TEST_DIR=$(mktemp -d)
CONFIG_DIR="$TEST_DIR/config"
TELEGO_CONFIG="$CONFIG_DIR/config.toml"
COMPOSE_FILE="$CONFIG_DIR/compose.yaml"
ENV_FILE="$CONFIG_DIR/.env"
LOCK_FILE="$TEST_DIR/manager.lock"

cleanup() {
    local code=$?
    if [ "$code" -ne 0 ] && check_container_exists; then
        docker logs --tail 40 "$CONTAINER_NAME" >&2 || true
    fi
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    if docker network inspect "$CADDY_NETWORK" >/dev/null 2>&1; then
        docker network rm "$CADDY_NETWORK" >/dev/null || code=1
    fi
    rm -rf "$TEST_DIR"
    exit "$code"
}
trap cleanup EXIT

# Только песочница; публичные DNS, сертификат и Telegram здесь не проверяются.
check_root() { :; }
print_qr() { :; }
get_ip() { echo 127.0.0.1; }
getent() { return 1; }
curl() {
    local arg
    for arg in "$@"; do
        if [[ "$arg" == https://*.invalid/* ]]; then return 1; fi
    done
    command curl "$@"
}

assert_mounted_config() {
    docker cp "$CONTAINER_NAME:/config.toml" "$TEST_DIR/mounted.toml" >/dev/null
    cmp -s "$TELEGO_CONFIG" "$TEST_DIR/mounted.toml"
}

assert_foreign_port_busy() {
    local CONTAINER_NAME="another-test-container"
    docker_port_in_use "$port"
    if is_port_available_for_telego "$port"; then return 1; fi
}

# Не публикуем тестовый домен в существующем Caddy и открываем MTProxy только локально.
mkdir -p "$CONFIG_DIR"
write_compose_file
sed -i '/^    labels:$/,/^    logging:$/ { /^    logging:$/!d; }' "$COMPOSE_FILE"
# shellcheck disable=SC2016 # Переменная должна остаться в YAML для интерполяции Compose.
sed -i 's|"${MTPROXY_PORT}:4433"|"127.0.0.1:${MTPROXY_PORT}:4433"|' "$COMPOSE_FILE"

port=$(find_free_port 48443)
main setup proxy.example.invalid "$port" > "$TEST_DIR/setup.log"
load_env
container_is_running "$CONTAINER_NAME"
assert_mounted_config
[ "$(stat -c '%a' "$CONFIG_DIR")" = 700 ]
[ "$(stat -c '%a' "$TELEGO_CONFIG")" = 600 ]
[ "$(stat -c '%a' "$ENV_FILE")" = 600 ]
is_port_available_for_telego "$port"
assert_foreign_port_busy

main add-user alice > "$TEST_DIR/users.log"
[ "$(active_secret_count)" -eq 2 ]
assert_mounted_config
main block-user alice >> "$TEST_DIR/users.log"
[[ "$(get_secret_entry alice)" == *:blocked ]]
assert_mounted_config
main unblock-user alice >> "$TEST_DIR/users.log"
[[ "$(get_secret_entry alice)" == *:active ]]
assert_mounted_config
echo "OK: setup, секреты, bind-mount и собственный порт"

users_before=$(list_secrets)
sed -i 's/log-level = "info"/log-level = "warn"/' "$TELEGO_CONFIG"
sed -i 's|^trusted-proxy-cidrs = .*|trusted-proxy-cidrs = [\n  "127.0.0.1/32", # ]\n]|' "$TELEGO_CONFIG"
printf '\n[middle-end]\nenabled = false\n' >> "$TELEGO_CONFIG"
printf '\nCUSTOM_IMAGE=scratchnet/telego:v0.6\n' >> "$ENV_FILE"
sed -i "s|^    image:.*$|    image: '\${CUSTOM_IMAGE}'|" "$COMPOSE_FILE"
main setup Proxy2.example.invalid "$port" > "$TEST_DIR/setup-repeat.log"
load_env
[ "$users_before" = "$(list_secrets)" ]
[ "$DOMAIN" = proxy2.example.invalid ]
grep -q '^log-level = "warn"$' "$TELEGO_CONFIG"
grep -q '^enabled = false$' "$TELEGO_CONFIG"
grep -q '^CUSTOM_IMAGE=scratchnet/telego:v0.6$' "$ENV_FILE"
assert_mounted_config
main restart >/dev/null
echo "OK: повторный setup сохраняет настройки; готовность проверяется при log-level=warn"

(
    cd "$TEST_DIR"
    main export >/dev/null
)
archive=$(find "$TEST_DIR" -maxdepth 1 -name 'mtproto-manager_*.tar.gz' -print)
main block-user alice >/dev/null
main import "$archive" >/dev/null
[[ "$(get_secret_entry alice)" == *:active ]]
assert_mounted_config
echo "OK: полный экспорт/импорт"

sed -i 's|^    image:.*$|    image: "scratchnet/telego:v0.6.8"|' "$COMPOSE_FILE"
[ "$(get_telego_image)" = scratchnet/telego:v0.6.8 ]
main update >/dev/null
[ "$(docker inspect -f '{{.Config.Image}}' "$CONTAINER_NAME")" = scratchnet/telego:v0.6.8 ]
echo "OK: выбор образа из Compose и update"

mkdir "$TEST_DIR/expected" "$TEST_DIR/bad"
cp "$TELEGO_CONFIG" "$COMPOSE_FILE" "$ENV_FILE" "$TEST_DIR/expected/"
cp "$TELEGO_CONFIG" "$TEST_DIR/bad/config.toml"
printf '\n[broken\n' >> "$TEST_DIR/bad/config.toml"
tar -czf "$TEST_DIR/bad.tar.gz" -C "$TEST_DIR/bad" config.toml
if main import "$TEST_DIR/bad.tar.gz" > "$TEST_DIR/bad-import.log" 2>&1; then
    echo "Невалидный TOML неожиданно принят." >&2
    exit 1
fi
container_is_running "$CONTAINER_NAME"
for file in config.toml compose.yaml .env; do
    cmp -s "$TEST_DIR/expected/$file" "$CONFIG_DIR/$file"
done
assert_mounted_config
echo "OK: неудачный импорт восстанавливает конфигурацию и работающий прокси"

main stop >/dev/null
if main import "$TEST_DIR/bad.tar.gz" > "$TEST_DIR/bad-import-stopped.log" 2>&1; then
    exit 1
fi
if container_is_running "$CONTAINER_NAME"; then
    echo "Откат запустил ранее остановленный контейнер." >&2
    exit 1
fi
main start >/dev/null
assert_mounted_config
main remove-user alice >/dev/null
if main block-user user1 > "$TEST_DIR/last-user.log" 2>&1; then exit 1; fi
if main remove-user user1 >> "$TEST_DIR/last-user.log" 2>&1; then exit 1; fi
[ "$(active_secret_count)" -eq 1 ]
echo "OK: stop/start, сохранение остановленного состояния и защита последнего пользователя"
