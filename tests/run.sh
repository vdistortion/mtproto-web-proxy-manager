#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/mtproto-manager.sh"

TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

CONFIG_DIR="$TEST_DIR"
TELEGO_CONFIG="$CONFIG_DIR/config.toml"
COMPOSE_FILE="$CONFIG_DIR/compose.yaml"
ENV_FILE="$CONFIG_DIR/.env"
LOCK_FILE="$TEST_DIR/manager.lock"
DOMAIN="proxy.example.com"
MTPROXY_PORT="8443"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_eq() {
    local expected="$1" actual="$2" label="$3"
    [ "$expected" = "$actual" ] || fail "$label (ожидалось '$expected', получено '$actual')"
}

assert_ok() {
    local label="$1"
    shift
    "$@" || fail "$label"
}

assert_fails() {
    local label="$1"
    shift
    if ( "$@" ) >/dev/null 2>&1; then
        fail "$label"
    fi
}

bash -s help < "$ROOT_DIR/mtproto-manager.sh" > "$TEST_DIR/stdin-help.log"
grep -q 'Использование:' "$TEST_DIR/stdin-help.log" || fail "запуск скрипта через stdin"

cat > "$TELEGO_CONFIG" <<'TOML'
[general]
log-level = "info"
carol-2 = "outside secrets"

[secrets] # пользователи
  alice = "0123456789abcdef0123456789abcdef" # активен
#   bob = "FEDCBA9876543210FEDCBA9876543210" # заблокирован

[performance]
prefer-ip = "prefer-ipv4"
# carol-2 = "outside secrets"
TOML

assert_eq \
    $'alice:0123456789abcdef0123456789abcdef:active\nbob:fedcba9876543210fedcba9876543210:blocked' \
    "$(list_secrets)" \
    "чтение активных и заблокированных секретов"
assert_eq "1" "$(active_secret_count)" "подсчёт активных пользователей"

cat > "$ENV_FILE" <<'ENV'
DOMAIN=proxy.example.com
MTPROXY_PORT=8443
ENV
load_env
assert_eq "scratchnet/telego:v0.6" "$(get_telego_image)" "образ по умолчанию"
assert_eq "proxy.example.com" "$DOMAIN" "чтение домена из env-файла"
(
    printf '  DOMAIN = "proxy.example.com" # домен\r\nMTPROXY_PORT=\04708443\047 # порт\r\n' > "$TEST_DIR/quoted.env"
    ENV_FILE="$TEST_DIR/quoted.env" load_env
    assert_eq "proxy.example.com" "$DOMAIN" "кавычки и комментарии в env-файле"
    assert_eq "08443" "$MTPROXY_PORT" "CRLF в env-файле"
)

secret_add "carol-2" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
assert_eq \
    "carol-2:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:active" \
    "$(get_secret_entry carol-2)" \
    "добавление секрета"

secret_edit block "carol-2"
assert_eq \
    "carol-2:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:blocked" \
    "$(get_secret_entry carol-2)" \
    "блокировка пользователя"

secret_edit unblock "carol-2"
assert_eq \
    "carol-2:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:active" \
    "$(get_secret_entry carol-2)" \
    "разблокировка пользователя"

secret_edit remove "bob"
assert_eq "" "$(get_secret_entry bob)" "удаление заблокированного пользователя"
grep -q '^prefer-ip = "prefer-ipv4"$' "$TELEGO_CONFIG" || fail "сохранение других секций TOML"
grep -q '^carol-2 = "outside secrets"$' "$TELEGO_CONFIG" || fail "блокировка не трогает другие секции"
grep -q '^# carol-2 = "outside secrets"$' "$TELEGO_CONFIG" || fail "разблокировка не трогает другие секции"
assert_eq "600" "$(stat -c '%a' "$TELEGO_CONFIG")" "права конфига после редактирования"

cat >> "$TELEGO_CONFIG" <<'TOML'

[web-proxy]
carrier = "websocket-lanes"

[upstream]
socks5 = "127.0.0.1:1080"
TOML
users_before=$(list_secrets)
printf '\n# пользовательские настройки\nCUSTOM_IMAGE=scratchnet/telego:v0.6.8\n' >> "$ENV_FILE"
write_server_config '"172.20.0.0/16"' "" ""
assert_eq "$users_before" "$(list_secrets)" "повторный setup сохраняет пользователей"
grep -q '^carrier = "websocket-lanes"$' "$TELEGO_CONFIG" || fail "сохранение выбранного carrier"
grep -q '^socks5 = "127.0.0.1:1080"$' "$TELEGO_CONFIG" || fail "сохранение ручных настроек"
grep -q '^mask-host = "proxy.example.com"$' "$TELEGO_CONFIG" || fail "настройка домена"
assert_eq "600" "$(stat -c '%a' "$ENV_FILE")" "права env-файла"
grep -q '^CUSTOM_IMAGE=scratchnet/telego:v0.6.8$' "$ENV_FILE" || fail "сохранение дополнительных env-переменных"
grep -q '^# пользовательские настройки$' "$ENV_FILE" || fail "сохранение комментариев env-файла"

test_first_setup() {
    local TELEGO_CONFIG="$TEST_DIR/first.toml"
    local ENV_FILE="$TEST_DIR/first.env"
    write_server_config '"172.20.0.0/16"' first "cccccccccccccccccccccccccccccccc"
    assert_eq "first:cccccccccccccccccccccccccccccccc:active" "$(list_secrets)" "первый пользователь"
    grep -q '^carrier = "websocket"$' "$TELEGO_CONFIG" || fail "carrier по умолчанию"
}
test_first_setup

test_multiline_subnets() {
    local TELEGO_CONFIG="$TEST_DIR/multiline.toml"
    local ENV_FILE="$TEST_DIR/multiline.env"
    cat > "$TELEGO_CONFIG" <<'TOML'
[secrets]
alice = "0123456789abcdef0123456789abcdef"

[web-proxy]
trusted-proxy-cidrs = [ # ] в комментарии не закрывает массив
    "172.20.0.0/16", # [ в комментарии не открывает массив
    'fd00::/64',
]
carrier = "https-lanes"

[performance]
idle-timeout = "10m"
TOML
    write_server_config '"172.21.0.0/16", "fd01::/64"' "" ""
    grep -q '^trusted-proxy-cidrs = \["172.21.0.0/16", "fd01::/64"\]$' "$TELEGO_CONFIG" \
        || fail "замена многострочного массива подсетей"
    if grep -qE '172\.20\.|fd00|^\]' "$TELEGO_CONFIG"; then
        fail "остатки прежнего массива подсетей"
    fi
    grep -q '^carrier = "https-lanes"$' "$TELEGO_CONFIG" || fail "carrier после многострочного массива"
    grep -q '^idle-timeout = "10m"$' "$TELEGO_CONFIG" || fail "секция после многострочного массива"

    sed -i 's/^trusted-proxy-cidrs = .*$/trusted-proxy-cidrs = [/' "$TELEGO_CONFIG"
    cp "$TELEGO_CONFIG" "$TEST_DIR/unterminated.toml"
    assert_fails "отклонение незакрытого массива" write_server_config '"172.21.0.0/16"' "" ""
    cmp -s "$TEST_DIR/unterminated.toml" "$TELEGO_CONFIG" || fail "незакрытый массив не меняет конфиг"
}
test_multiline_subnets

# shellcheck disable=SC2329
test_setup_rollback() {
    local CONFIG_DIR="$TEST_DIR/setup-rollback"
    local TELEGO_CONFIG="$CONFIG_DIR/config.toml"
    local COMPOSE_FILE="$CONFIG_DIR/compose.yaml"
    local ENV_FILE="$CONFIG_DIR/.env"
    local DOMAIN="" MTPROXY_PORT=8443 file
    check_root() { :; }
    check_docker() { :; }
    is_port_available_for_telego() { return 0; }
    get_ip() { :; }
    getent() { return 1; }
    generate_secret() { printf '%s' 0123456789abcdef0123456789abcdef; }
    docker() {
        case "$1 ${2:-}" in
            'network inspect')
                if [ "${4:-}" = -f ]; then echo 172.20.0.0/16; fi
                ;;
            *) return 1 ;;
        esac
    }
    up_and_check() { return 1; }

    if (setup_server proxy.example.com 8443) > "$TEST_DIR/setup-rollback.log" 2>&1; then
        fail "ошибка первого запуска"
    fi
    grep -q 'Запуск контейнера' "$TEST_DIR/setup-rollback.log" || fail "setup дошёл до запуска"
    for file in config.toml compose.yaml .env; do
        [ ! -e "$CONFIG_DIR/$file" ] || fail "неудачный первый setup оставил $file"
    done

    DOMAIN=""
    MTPROXY_PORT=8443
    write_compose_file
    write_env_file
    cp "$COMPOSE_FILE" "$TEST_DIR/before-setup.yaml"
    cp "$ENV_FILE" "$TEST_DIR/before-setup.env"
    assert_fails "ошибка setup после install" setup_server proxy.example.com 8443
    cmp -s "$TEST_DIR/before-setup.yaml" "$COMPOSE_FILE" || fail "setup сохраняет исходный Compose"
    cmp -s "$TEST_DIR/before-setup.env" "$ENV_FILE" || fail "setup сохраняет исходный env-файл"
    [ ! -e "$TELEGO_CONFIG" ] || fail "setup оставил новый config.toml"
}
( test_setup_rollback )

write_compose_file
sed -i 's|^    image: scratchnet/telego:v0.6$|    image: scratchnet/telego:v0.6.8|' "$COMPOSE_FILE"
load_env
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    docker compose --env-file "$TEST_DIR/.env" -f "$COMPOSE_FILE" config --quiet \
        || fail "валидация Docker Compose"
    assert_eq "scratchnet/telego:v0.6.8" "$(get_telego_image)" "образ берётся из Compose-файла"
    sed -i "s|    image: scratchnet/telego:v0.6.8|    image: '\${CUSTOM_IMAGE}'|" "$COMPOSE_FILE"
    printf 'CUSTOM_IMAGE=scratchnet/telego:v0.6.8\n' >> "$ENV_FILE"
    assert_eq "scratchnet/telego:v0.6.8" "$(get_telego_image)" "Compose разрешает переменные и кавычки"
fi

(
    backup_dir=$(backup_server_config)
    cp "$TELEGO_CONFIG" "$TEST_DIR/expected.toml"
    cp "$ENV_FILE" "$TEST_DIR/expected.env"
    printf 'broken\n' > "$TELEGO_CONFIG"
    printf 'broken\n' > "$ENV_FILE"
    check_container_exists() { return 1; }
    rollback_server_config "$backup_dir" missing
    cmp -s "$TEST_DIR/expected.toml" "$TELEGO_CONFIG" || fail "откат всех настроек"
    cmp -s "$TEST_DIR/expected.env" "$ENV_FILE" || fail "откат домена и порта"
    [ ! -d "$backup_dir" ] || fail "очистка резервной копии"
)

compose() { :; }
restart_and_check() { return 0; }
apply_secret_change add "dave" "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" >/dev/null
assert_eq "dave:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb:active" \
    "$(get_secret_entry dave)" \
    "успешная транзакция изменения секрета"

restart_attempts=0
restart_and_check() {
    restart_attempts=$((restart_attempts + 1))
    [ "$restart_attempts" -gt 1 ]
}
if apply_secret_change block "dave" >/dev/null 2>&1; then
    fail "откат изменения при ошибке перезапуска"
fi
assert_eq "dave:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb:active" \
    "$(get_secret_entry dave)" \
    "откат секрета после неудачного перезапуска"
[ -z "$(find "$TEST_DIR" -maxdepth 1 -name 'config.toml.bak.*' -print)" ] || fail "очистка копии после отката"
restart_and_check() { return 0; }

assert_ok "валидация имени пользователя" validate_username "alice_2-test"
assert_fails "отклонение некорректного имени" validate_username "bad name"
assert_ok "валидация домена" validate_domain "proxy.example.com"
assert_fails "отклонение URL вместо домена" validate_domain "https://proxy.example.com"
assert_fails "отклонение IP вместо домена" validate_domain "127.0.0.1"
assert_fails "отклонение числовой последней DNS-метки" validate_domain "proxy.example.123"
assert_fails "отклонение hex-формы последней DNS-метки" validate_domain "proxy.example.0xFF"
long_label=$(printf '%064d' 0)
assert_fails "ограничение длины DNS-метки" validate_domain "${long_label}.example.com"

assert_eq "8443" "$(validate_mtproxy_port 08443)" "нормализация порта с ведущим нулём"
assert_eq "65535" "$(validate_mtproxy_port 65535)" "верхняя граница порта"
assert_fails "отклонение порта 80" validate_mtproxy_port 80
assert_fails "отклонение порта 443" validate_mtproxy_port 443
assert_fails "отклонение порта выше диапазона" validate_mtproxy_port 65536
# shellcheck disable=SC2329 # Заглушки вызываются косвенно функциями менеджера.
(
    docker_port_in_use() { return 1; }
    is_port_free() { return 1; }
    docker() { echo 8443; }
    container_is_running() { return 1; }
    assert_fails "старое сопоставление порта не разрешает занятый порт" is_port_available_for_telego 8443
    container_is_running() { return 0; }
    assert_ok "повторное использование порта работающего контейнера" is_port_available_for_telego 8443
)
is_port_available_for_telego() { return 1; }
assert_fails "не искать порт выше 65535" find_free_port 65535
(
    is_port_available_for_telego() { [ "$1" != 79 ] && [ "$1" != 442 ]; }
    assert_eq "81" "$(find_free_port 79)" "не занимать порт 80 Caddy"
    assert_eq "444" "$(find_free_port 442)" "не занимать порт 443 Caddy"
)

assert_eq "70726f78792e6578616d706c652e636f6d" \
    "$(domain_to_hex "$DOMAIN")" \
    "кодирование домена для ee-ссылки"

links=$(CYAN="" NC="" print_user_links "0123456789abcdef0123456789abcdef")
assert_eq \
    "  WEB-прокси:      https://t.me/webproxy?server=proxy.example.com&secret=0123456789abcdef0123456789abcdef
  WEB-прокси (dd): https://t.me/webproxy?server=proxy.example.com&secret=dd0123456789abcdef0123456789abcdef
  MTProxy (ee):    https://t.me/proxy?server=proxy.example.com&port=8443&secret=ee0123456789abcdef0123456789abcdef70726f78792e6578616d706c652e636f6d
  MTProxy (dd):    https://t.me/proxy?server=proxy.example.com&port=8443&secret=dd0123456789abcdef0123456789abcdef" \
    "$links" \
    "порядок и формат всех четырёх ссылок"

# shellcheck disable=SC2329 # Заглушка вызывается из print_qr.
(
    qrencode() { printf '%s\n' "$@" > "$TEST_DIR/qr.args"; }
    qr_output=$(CYAN="" NC="" print_qr "0123456789abcdef0123456789abcdef")
    assert_eq \
        $'-t\nansiutf8\nhttps://t.me/webproxy?server=proxy.example.com&secret=0123456789abcdef0123456789abcdef' \
        "$(cat "$TEST_DIR/qr.args")" \
        "QR-код для обычного WEB-прокси"
    [[ "$qr_output" == *"QR-код (WEB-прокси):"* ]] || fail "подпись WEB QR-кода"
)

# shellcheck disable=SC2329
(
    command() {
        if [ "${1:-}" = -v ] && [ "${2:-}" = qrencode ]; then return 1; fi
        builtin command "$@"
    }
    assert_eq "" "$(print_qr "0123456789abcdef0123456789abcdef")" "работа без qrencode"
)

# shellcheck disable=SC2329 # Заглушки вызываются из list_users.
(
    check_root() { :; }
    container_is_running() { return 1; }
    TELEGO_CONFIG="$TEST_DIR/list-users.toml"
    cat > "$TELEGO_CONFIG" <<'TOML'
[secrets]
alice = "0123456789abcdef0123456789abcdef"
# bob = "fedcba9876543210fedcba9876543210"
TOML
    users=$(list_users)
    [[ "$users" == *"https://t.me/webproxy?server=proxy.example.com&secret=0123456789abcdef0123456789abcdef"* ]] \
        || fail "WEB-ссылка в списке пользователей"
    [[ "$users" != *"https://t.me/proxy?"* ]] || fail "список пользователей не предлагает ee вместо WEB"
    [[ "$users" != *"secret=fedcba9876543210fedcba9876543210"* ]] || fail "ссылка заблокированного пользователя скрыта"
)

BINARY_PATH="$TEST_DIR/bin/mtproto-manager"
SCRIPT_URL="file:///not-a-real-script"
curl() { return 1; }
mkdir -p "$(dirname "$BINARY_PATH")"
install_manager_binary >/dev/null
cmp -s "$ROOT_DIR/mtproto-manager.sh" "$BINARY_PATH" || fail "установка из текущего локального файла"

# shellcheck disable=SC2329 # main здесь только записывает выбранную команду.
(
    clear() { :; }
    main() { printf '%s\n' "$@" > "$TEST_DIR/menu-command.args"; }
    while read -r menu_choice expected_command argument; do
        if [ -n "$argument" ]; then
            printf '%s\n' "$menu_choice" "$argument" '' 0 | show_menu > "$TEST_DIR/menu-route.log"
            expected=$(printf '%s\n' "$expected_command" "$argument")
        else
            printf '%s\n' "$menu_choice" '' 0 | show_menu > "$TEST_DIR/menu-route.log"
            expected="$expected_command"
        fi
        assert_eq "$expected" "$(cat "$TEST_DIR/menu-command.args")" "пункт меню $menu_choice"
    done <<'MENU'
1 add-user alice
2 remove-user alice
3 list-users
4 show-user alice
5 block-user alice
6 unblock-user alice
7 start
8 stop
9 restart
10 status
11 show-traffic
12 update
13 setup
14 export
15 import backup with spaces.tar.gz
16 uninstall
MENU
    : > "$TEST_DIR/menu-command.args"
    printf '0\n' | show_menu > "$TEST_DIR/menu-exit.log"
    [ ! -s "$TEST_DIR/menu-command.args" ] || fail "выход не запускает команду"
    [ "$(grep -c 'Выход' "$TEST_DIR/menu-exit.log")" -eq 1 ] || fail "немедленный выход из меню"
)

(
    clear() { :; }
    check_root() { :; }
    add_user() { echo 'ошибка команды'; exit 1; }
    printf '1\nalice\n\n0\n' | show_menu > "$TEST_DIR/menu.log"
    [ "$(grep -c 'Выход' "$TEST_DIR/menu.log")" -eq 2 ] || fail "меню сохраняется после ошибки"
    grep -q 'ошибка команды' "$TEST_DIR/menu.log" || fail "меню выполняет выбранную команду"
)

(
    check_root() { :; }
    stop_all() { touch "$TEST_DIR/lock-held"; sleep 1; }
    start_all() { touch "$TEST_DIR/command-ran"; }
    main stop &
    pid=$!
    for ((attempt=0; attempt<100; attempt++)); do
        [ -f "$TEST_DIR/lock-held" ] && break
        sleep 0.01
    done
    [ -f "$TEST_DIR/lock-held" ] || fail "первая команда захватила блокировку"
    assert_fails "запрет одновременных управляющих команд" main start
    wait "$pid"
    main start
    [ -f "$TEST_DIR/command-ran" ] || fail "освобождение блокировки после команды"
    stop_all() { exit 1; }
    assert_fails "ошибка управляющей команды" main stop
    main start
)

# install запускаем через stdin; Docker, curl и пакетный менеджер заменяем заглушками.
cat > "$TEST_DIR/install-mocks.sh" <<'BASH'
CONFIG_DIR="$TEST_INSTALL_ROOT/config"
TELEGO_CONFIG="$CONFIG_DIR/config.toml"
COMPOSE_FILE="$CONFIG_DIR/compose.yaml"
ENV_FILE="$CONFIG_DIR/.env"
BINARY_PATH="$TEST_INSTALL_ROOT/bin/mtproto-manager"
LOCK_FILE="$TEST_INSTALL_ROOT/manager.lock"
check_root() { :; }
docker() { return 0; }
command() {
    if [ "${1:-}" = -v ] && [ "${2:-}" = qrencode ]; then return 1; fi
    if [ "${1:-}" = -v ] && [ "${2:-}" = apt-get ]; then return 0; fi
    builtin command "$@"
}
apt-get() { return 1; }
curl() {
    while [ "$#" -gt 0 ]; do
        if [ "$1" = -o ]; then cp "$TEST_SCRIPT_PATH" "$2"; return; fi
        shift
    done
    return 1
}
BASH
awk -v mocks="$TEST_DIR/install-mocks.sh" '
    /^if \[\[ "\$\{BASH_SOURCE\[0\]/ {
        while ((getline line < mocks) > 0) print line
        close(mocks)
    }
    { print }
' "$ROOT_DIR/mtproto-manager.sh" > "$TEST_DIR/stdin-install.sh"
mkdir -p "$TEST_DIR/pipe-install/bin"
TEST_INSTALL_ROOT="$TEST_DIR/pipe-install" TEST_SCRIPT_PATH="$ROOT_DIR/mtproto-manager.sh" \
    setsid --wait bash -s install < "$TEST_DIR/stdin-install.sh" > "$TEST_DIR/install.log"
cmp -s "$ROOT_DIR/mtproto-manager.sh" "$TEST_DIR/pipe-install/bin/mtproto-manager" \
    || fail "самоустановка при запуске через stdin"
grep -q 'QR-коды недоступны' "$TEST_DIR/install.log" || fail "установка не зависит от qrencode"

test_imports() {
    local CONFIG_DIR="$TEST_DIR/import-server"
    local TELEGO_CONFIG="$CONFIG_DIR/config.toml"
    local COMPOSE_FILE="$CONFIG_DIR/compose.yaml"
    local ENV_FILE="$CONFIG_DIR/.env"
    local stage="$TEST_DIR/archive" file start_result=0
    mkdir -p "$stage"
    cp "$TEST_DIR/config.toml" "$stage/config.toml"
    cp "$TEST_DIR/compose.yaml" "$stage/compose.yaml"
    cp "$TEST_DIR/.env" "$stage/.env"

    check_root() { :; }
    check_docker() { :; }
    docker() { return 1; }
    compose() {
        if grep -q '^invalid yaml' "$COMPOSE_FILE"; then return 1; fi
        if [ "${2:-}" = "--images" ]; then echo scratchnet/telego:v0.6; fi
        return 0
    }
    up_and_check() { return "$start_result"; }

    tar -czf "$TEST_DIR/good.tar.gz" -C "$stage" config.toml compose.yaml .env
    import_users "$TEST_DIR/good.tar.gz" >/dev/null
    for file in config.toml compose.yaml .env; do
        cmp -s "$stage/$file" "$CONFIG_DIR/$file" || fail "полный импорт: $file"
        assert_eq "600" "$(stat -c '%a' "$CONFIG_DIR/$file")" "права импортированного $file"
    done

    mv "$stage/config.toml" "$stage/saved.toml"
    ln -s saved.toml "$stage/config.toml"
    tar -czf "$TEST_DIR/symlink.tar.gz" -C "$stage" config.toml
    assert_fails "отклонение символических ссылок" import_users "$TEST_DIR/symlink.tar.gz"
    rm "$stage/config.toml"
    mv "$stage/saved.toml" "$stage/config.toml"

    tar --hard-dereference -czf "$TEST_DIR/duplicate.tar.gz" -C "$stage" config.toml config.toml
    assert_fails "отклонение дубликатов" import_users "$TEST_DIR/duplicate.tar.gz"
    tar -czf "$TEST_DIR/traversal.tar.gz" --transform='s|^config.toml$|../config.toml|' -C "$stage" config.toml
    assert_fails "отклонение путей с ../" import_users "$TEST_DIR/traversal.tar.gz"
    printf 'not an archive\n' > "$TEST_DIR/broken.tar.gz"
    assert_fails "отклонение повреждённого архива" import_users "$TEST_DIR/broken.tar.gz"
    printf 'DOMAIN=invalid/host\nMTPROXY_PORT=8443\n' > "$stage/.env"
    tar -czf "$TEST_DIR/bad-env.tar.gz" -C "$stage" config.toml .env
    assert_fails "валидация домена до импорта" import_users "$TEST_DIR/bad-env.tar.gz"
    printf 'invalid yaml\n' > "$stage/compose.yaml"
    tar -czf "$TEST_DIR/bad-compose.tar.gz" -C "$stage" config.toml compose.yaml
    assert_fails "валидация Compose до импорта" import_users "$TEST_DIR/bad-compose.tar.gz"
    for file in config.toml compose.yaml .env; do
        cmp -s "$TEST_DIR/$file" "$CONFIG_DIR/$file" || fail "невалидный архив не меняет $file"
    done

    printf '[secrets]\nchanged = "cccccccccccccccccccccccccccccccc"\n' > "$stage/config.toml"
    tar -czf "$TEST_DIR/changed.tar.gz" -C "$stage" config.toml
    start_result=1
    assert_fails "ошибка запуска после импорта" import_users "$TEST_DIR/changed.tar.gz"
    for file in config.toml compose.yaml .env; do
        cmp -s "$TEST_DIR/$file" "$CONFIG_DIR/$file" || fail "откат импортированного $file"
    done

    mkdir -p "$TEST_DIR/exports"
    (
        cd "$TEST_DIR/exports"
        date() { printf '20000101_000000\n'; }
        export_users >/dev/null
        export_users >/dev/null
        [ -f mtproto-manager_20000101_000000.tar.gz ] || fail "первый экспорт"
        [ -f mtproto-manager_20000101_000000_1.tar.gz ] || fail "экспорт не затирает предыдущий"
        assert_eq "600" "$(stat -c '%a' mtproto-manager_20000101_000000.tar.gz)" "права экспорта"

        ln -s "$TEST_DIR/dangling.tar.gz" mtproto-manager_20000101_000000_2.tar.gz
        export_users >/dev/null
        [ -L mtproto-manager_20000101_000000_2.tar.gz ] || fail "экспорт сохраняет символическую ссылку"
        [ ! -e "$TEST_DIR/dangling.tar.gz" ] || fail "экспорт записал архив по символической ссылке"
        [ -f mtproto-manager_20000101_000000_3.tar.gz ] || fail "экспорт обходит имя символической ссылки"

        # shellcheck disable=SC2329
        tar() { printf 'partial archive\n' > "$2"; return 1; }
        assert_fails "ошибка упаковки архива" export_users
        [ ! -e mtproto-manager_20000101_000000_4.tar.gz ] || fail "экспорт оставил повреждённый архив"
        [ -z "$(find . -maxdepth 1 -name '.mtproto-manager_*' -print)" ] || fail "экспорт оставил временный файл"
    )

    CONFIG_DIR="$TEST_DIR/first-import"
    TELEGO_CONFIG="$CONFIG_DIR/config.toml"
    COMPOSE_FILE="$CONFIG_DIR/compose.yaml"
    ENV_FILE="$CONFIG_DIR/.env"
    assert_fails "неудачный первый импорт" import_users "$TEST_DIR/good.tar.gz"
    for file in config.toml compose.yaml .env; do
        [ ! -f "$CONFIG_DIR/$file" ] || fail "неудачный первый импорт оставил $file"
    done
}
( test_imports )

echo "OK: локальные тесты пройдены."
