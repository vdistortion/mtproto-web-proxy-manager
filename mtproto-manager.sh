#!/usr/bin/env bash

set -euo pipefail

# Пути и параметры контейнера

CONFIG_DIR="/etc/mtproto-manager"
TELEGO_CONFIG="$CONFIG_DIR/config.toml"
COMPOSE_FILE="$CONFIG_DIR/compose.yaml"
ENV_FILE="$CONFIG_DIR/.env"
BINARY_PATH="/usr/local/bin/mtproto-manager"
LOCK_FILE="/run/mtproto-manager.lock"
SCRIPT_URL="https://raw.githubusercontent.com/vdistortion/mtproto-web-proxy-manager/main/mtproto-manager.sh"

# Движок telEgo: https://github.com/Scratch-net/telego
DOCKER_IMAGE="scratchnet/telego:v0.6"
CONTAINER_NAME="telego"

CADDY_NETWORK="caddy"

# Порты внутри контейнера telego:
#   4433 — MTProxy (публикуется на хосте как ${MTPROXY_PORT})
#   8080 — HTTP для Caddy в сети caddy, без публикации на хосте
TELEGO_MTPROXY_LISTEN="0.0.0.0:4433"
TELEGO_WEB_LISTEN="0.0.0.0:8080"

DEFAULT_MTPROXY_PORT=8443

DOMAIN=""
MTPROXY_PORT=""

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Проверки окружения и работа с .env

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}Ошибка: скрипт должен запускаться от root (sudo).${NC}"
        exit 1
    fi
}

check_docker() {
    if ! command -v docker &>/dev/null; then
        echo -e "${RED}Ошибка: Docker не установлен. Запустите: mtproto-manager install${NC}"
        exit 1
    fi
    if ! docker info &>/dev/null; then
        echo -e "${RED}Ошибка: Docker демон не запущен. Запустите: systemctl start docker${NC}"
        exit 1
    fi
    check_docker_compose
}

check_docker_compose() {
    if ! docker compose version &>/dev/null; then
        echo -e "${RED}Ошибка: не найден Docker Compose v2 (команда: docker compose).${NC}"
        echo -e "Установите Docker Compose plugin и повторите команду."
        exit 1
    fi
}

compose() {
    if [ -f "$ENV_FILE" ]; then
        docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "$@"
    else
        docker compose -f "$COMPOSE_FILE" "$@"
    fi
}

get_telego_image() {
    if [ -f "$COMPOSE_FILE" ]; then
        DOMAIN="$DOMAIN" MTPROXY_PORT="${MTPROXY_PORT:-$DEFAULT_MTPROXY_PORT}" \
            compose config --images "$CONTAINER_NAME"
    else
        printf '%s\n' "$DOCKER_IMAGE"
    fi
}

get_ip() {
    local ip
    ip=$(curl -fsS -4 --max-time 5 https://api.ipify.org 2>/dev/null \
      || curl -fsS -4 --max-time 5 https://icanhazip.com 2>/dev/null \
      || true)
    if [[ "$ip" =~ ([0-9]{1,3}\.){3}[0-9]{1,3} ]]; then
        printf '%s\n' "${BASH_REMATCH[0]}"
    fi
}

is_port_free() {
    local port="$1" sockets
    sockets=$(timeout 1 ss -H -lnt 2>/dev/null) || return 1
    ! grep -Fq ":${port} " <<< "$sockets"
}

docker_port_in_use() {
    local port="$1" name
    local containers
    containers=$(docker ps -a --filter "publish=${port}/tcp" --format '{{.Names}}' 2>/dev/null || true)
    while IFS= read -r name; do
        [ -z "$name" ] && continue
        [ "$name" = "$CONTAINER_NAME" ] && continue
        return 0
    done <<< "$containers"
    return 1
}

is_port_available_for_telego() {
    local p="$1" current_port
    docker_port_in_use "$p" && return 1
    if is_port_free "$p"; then
        return 0
    fi
    current_port=$(docker inspect \
        -f '{{with (index .HostConfig.PortBindings "4433/tcp")}}{{(index . 0).HostPort}}{{end}}' \
        "$CONTAINER_NAME" 2>/dev/null || true)
    [ "$current_port" = "$p" ] && container_is_running "$CONTAINER_NAME"
}

find_free_port() {
    local current_port="${1:-$DEFAULT_MTPROXY_PORT}"
    while (( current_port <= 65535 )); do
        if (( current_port != 80 && current_port != 443 )) && is_port_available_for_telego "$current_port"; then
            echo "$current_port"
            return 0
        fi
        (( current_port++ )) || true
    done
    echo -e "${RED}Ошибка: свободных портов не найдено.${NC}" >&2
    return 1
}

load_env() {
    DOMAIN=""
    MTPROXY_PORT=""
    if [ -f "$ENV_FILE" ]; then
        local values key value
        values=$(awk '
            /^[[:space:]]*(DOMAIN|MTPROXY_PORT)[[:space:]]*=/ {
                key=$0; sub(/^[[:space:]]*/, "", key); sub(/[[:space:]]*=.*/, "", key)
                value=$0; sub(/^[^=]*=[[:space:]]*/, "", value)
                sub(/[[:space:]]+#.*$/, "", value); sub(/[[:space:]]*$/, "", value)
                quote=substr(value, 1, 1)
                if ((quote == "\"" || quote == sprintf("%c", 39)) && substr(value, length(value), 1) == quote)
                    value=substr(value, 2, length(value)-2)
                print key "=" value
            }
        ' "$ENV_FILE") || return 1
        while IFS='=' read -r key value; do
            case "$key" in
                DOMAIN)       DOMAIN="$value" ;;
                MTPROXY_PORT) MTPROXY_PORT="$value" ;;
            esac
        done <<< "$values"
    fi
}

write_env_file() {
    local input=/dev/null tmp
    [ -f "$ENV_FILE" ] && input="$ENV_FILE"
    tmp=$(mktemp "${ENV_FILE}.tmp.XXXXXX") || return 1
    if ! awk -v domain="$DOMAIN" -v port="$MTPROXY_PORT" '
        /^[[:space:]]*DOMAIN[[:space:]]*=/ {
            if (!domain_written++) print "DOMAIN=" domain
            next
        }
        /^[[:space:]]*MTPROXY_PORT[[:space:]]*=/ {
            if (!port_written++) print "MTPROXY_PORT=" port
            next
        }
        { print }
        END {
            if (!domain_written) print "DOMAIN=" domain
            if (!port_written) print "MTPROXY_PORT=" port
        }
    ' "$input" > "$tmp" || ! chmod 600 "$tmp" || ! mv -f "$tmp" "$ENV_FILE"; then
        rm -f "$tmp"
        return 1
    fi
}

require_setup() {
    if [ ! -f "$ENV_FILE" ] || [ ! -f "$COMPOSE_FILE" ] || [ ! -f "$TELEGO_CONFIG" ]; then
        echo -e "${RED}Ошибка: прокси не настроен. Выполните:${NC}"
        echo -e "  ${CYAN}mtproto-manager install${NC}"
        echo -e "  ${CYAN}mtproto-manager setup${NC}"
        exit 1
    fi
    load_env
    if [ -z "$DOMAIN" ]; then
        echo -e "${RED}Ошибка: домен не задан. Запустите: mtproto-manager setup${NC}"
        exit 1
    fi
    if ! validate_domain "$DOMAIN"; then
        echo -e "${RED}Ошибка: некорректный DOMAIN в ${ENV_FILE}. Запустите setup заново.${NC}"
        exit 1
    fi
    DOMAIN="${DOMAIN,,}"
    local normalized_port
    if ! normalized_port=$(validate_mtproxy_port "$MTPROXY_PORT"); then
        echo -e "${RED}Ошибка: некорректный MTPROXY_PORT в ${ENV_FILE}. Запустите setup заново.${NC}"
        exit 1
    fi
    MTPROXY_PORT="$normalized_port"
}

check_container_exists() {
    docker inspect --type container "$CONTAINER_NAME" &>/dev/null
}

container_is_running() {
    [ "$(docker inspect --type container -f '{{.State.Running}}' "$1" 2>/dev/null || true)" = "true" ]
}

# Секция [secrets]

# Формат вывода: имя:секрет:статус (active|blocked)
list_secrets() {
    [ -f "$TELEGO_CONFIG" ] || return 0
    awk '
        /^[[:space:]]*\[secrets\][[:space:]]*(#.*)?$/ { insec=1; next }
        /^[[:space:]]*\[/ { insec=0; next }
        !insec { next }
        {
            blocked=0
            line=$0
            if (line ~ /^[[:space:]]*#/) {
                blocked=1
                sub(/^[[:space:]]*#[[:space:]]*/, "", line)
            }
            if (line !~ /^[[:space:]]*[A-Za-z0-9_-]+[[:space:]]*=[[:space:]]*"[0-9A-Fa-f]+"[[:space:]]*(#.*)?$/) next
            name=line; sub(/[[:space:]]*=.*/, "", name)
            sub(/^[[:space:]]*/, "", name)
            secret=line; sub(/^[^"]*"/, "", secret); sub(/".*/, "", secret)
            if (length(secret) != 32) next
            print name ":" tolower(secret) ":" (blocked ? "blocked" : "active")
        }
    ' "$TELEGO_CONFIG"
}

active_secret_count() {
    list_secrets | awk -F: '$3 == "active" { count++ } END { print count + 0 }'
}

get_secret_entry() {
    local username="$1"
    list_secrets | awk -F: -v u="$username" '$1 == u && !found { print; found=1 }'
}

require_secret_entry() {
    local username="$1" entry
    entry=$(get_secret_entry "$username") || return 1
    if [ -z "$entry" ]; then
        echo -e "${RED}Пользователь '${username}' не найден.${NC}" >&2
        return 1
    fi
    printf '%s\n' "$entry"
}

rewrite_telego_config() {
    local program="$1" tmp
    shift

    tmp=$(mktemp "${TELEGO_CONFIG}.tmp.XXXXXX") || return 1
    if ! awk "$@" "$program" "$TELEGO_CONFIG" > "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    if ! chmod 600 "$tmp" || ! mv -f "$tmp" "$TELEGO_CONFIG"; then
        rm -f "$tmp"
        return 1
    fi
    return 0
}

secret_add() {
    local username="$1" secret="$2" entry
    entry="${username} = \"${secret}\""
    # shellcheck disable=SC2016
    rewrite_telego_config '
        /^[[:space:]]*\[secrets\][[:space:]]*(#.*)?$/ && !done { print; print entry; done=1; next }
        { print }
        END { if (!done) { print ""; print "[secrets]"; print entry } }
    ' -v entry="$entry"
}

secret_edit() {
    local action="$1" username="$2"
    # shellcheck disable=SC2016
    rewrite_telego_config '
        /^[[:space:]]*\[secrets\][[:space:]]*(#.*)?$/ { insec=1; print; next }
        /^[[:space:]]*\[/ { insec=0 }
        insec && $0 ~ ("^[[:space:]]*#?[[:space:]]*" n "[[:space:]]*=") {
            if (action == "remove") next
            if (action == "block" && $0 !~ /^[[:space:]]*#/) $0="# " $0
            if (action == "unblock") sub(/^[[:space:]]*#[[:space:]]*/, "")
        }
        { print }
    ' -v action="$action" -v n="$username"
}

# Секреты и ссылки

generate_secret() {
    local raw secret image
    image=$(get_telego_image) || return 1
    [ -n "$image" ] || return 1
    # generate выводит секрет в stderr, поэтому читаем оба потока.
    if ! raw=$(docker run --rm "$image" generate "$DOMAIN" 2>&1); then
        return 1
    fi
    # shellcheck disable=SC2001 # sed убирает ANSI-коды цвета из вывода.
    raw=$(sed 's/\x1b\[[0-9;]*m//g' <<< "$raw")
    if [[ "$raw" =~ secret=([0-9a-f]{32})([^0-9a-f]|$) ]]; then
        secret="${BASH_REMATCH[1]}"
    else
        return 1
    fi
    printf '%s' "$secret"
}

domain_to_hex() {
    printf '%s' "$1" | od -An -tx1 | tr -d ' \n'
}

print_user_links() {
    local secret="$1"
    local ee_secret dd_secret
    ee_secret="ee${secret}$(domain_to_hex "$DOMAIN")"
    dd_secret="dd${secret}"
    echo -e "  WEB-прокси:      ${CYAN}https://t.me/webproxy?server=${DOMAIN}&secret=${secret}${NC}"
    echo -e "  WEB-прокси (dd): ${CYAN}https://t.me/webproxy?server=${DOMAIN}&secret=${dd_secret}${NC}"
    echo -e "  MTProxy (ee):    ${CYAN}https://t.me/proxy?server=${DOMAIN}&port=${MTPROXY_PORT}&secret=${ee_secret}${NC}"
    echo -e "  MTProxy (dd):    ${CYAN}https://t.me/proxy?server=${DOMAIN}&port=${MTPROXY_PORT}&secret=${dd_secret}${NC}"
}

print_qr() {
    local secret="$1"
    if ! command -v qrencode &>/dev/null; then
        return
    fi
    echo ""
    echo -e "${CYAN}QR-код (WEB-прокси):${NC}"
    qrencode -t ansiutf8 "https://t.me/webproxy?server=${DOMAIN}&secret=${secret}"
}

# Проверка запуска и откат конфигурации

wait_telego_started() {
    # Обычный HTTP-запрос к WEB-слушателю должен получить 418.
    local ip status attempt
    for ((attempt = 0; attempt < 30; attempt++)); do
        sleep 1
        container_is_running "$CONTAINER_NAME" || continue
        ip=$(docker inspect -f "{{with index .NetworkSettings.Networks \"$CADDY_NETWORK\"}}{{.IPAddress}}{{end}}" \
            "$CONTAINER_NAME" 2>/dev/null || true)
        [ -n "$ip" ] || continue
        status=$(curl --noproxy '*' -s --max-time 1 -o /dev/null -w '%{http_code}' \
            -H "Host: $DOMAIN" "http://${ip}:8080/" || true)
        [ "$status" = "418" ] && return 0
    done
    return 1
}

restart_and_check() {
    compose restart "$CONTAINER_NAME" >/dev/null || return 1
    wait_telego_started
}

up_and_check() {
    compose up -d --force-recreate "$CONTAINER_NAME" >/dev/null || return 1
    wait_telego_started
}

rollback_config() {
    local backup="$1"
    if cp -p "$backup" "$TELEGO_CONFIG" && restart_and_check; then
        rm -f "$backup"
    else
        echo -e "${RED}Не удалось восстановить работу прокси. Резервная копия: ${backup}${NC}" >&2
        return 1
    fi
}

apply_secret_change() {
    local action="$1" mutator backup
    shift

    case "$action" in
        add)     mutator=secret_add ;;
        remove|block|unblock)
            mutator=secret_edit
            set -- "$action" "$@"
            ;;
        *)
            echo -e "${RED}Внутренняя ошибка: неизвестное изменение секрета.${NC}"
            return 1
            ;;
    esac

    backup=$(mktemp "${TELEGO_CONFIG}.bak.XXXXXX") || return 1
    if ! cp -p "$TELEGO_CONFIG" "$backup"; then
        rm -f "$backup"
        echo -e "${RED}Ошибка: не удалось сохранить резервную копию конфига.${NC}"
        return 1
    fi

    if ! "$mutator" "$@"; then
        rm -f "$backup"
        echo -e "${RED}Ошибка: не удалось записать секцию [secrets] (изменение: ${action}).${NC}"
        return 1
    fi

    echo -e "${CYAN}Перезапуск ${CONTAINER_NAME}...${NC}"
    if restart_and_check; then
        rm -f "$backup"
        return 0
    fi

    rollback_config "$backup" || true
    print_telego_failure
    return 1
}

print_telego_failure() {
    echo -e "${RED}Ошибка: контейнер ${CONTAINER_NAME} не запустился или конфигурация невалидна.${NC}"
    echo -e "Логи: ${CYAN}docker logs ${CONTAINER_NAME}${NC}"
}

backup_server_config() {
    local backup_dir file
    backup_dir=$(mktemp -d "$CONFIG_DIR/.backup.XXXXXX") || return 1
    for file in config.toml compose.yaml .env; do
        if [ -f "$CONFIG_DIR/$file" ] && ! cp -p "$CONFIG_DIR/$file" "$backup_dir/$file"; then
            rm -rf "$backup_dir"
            return 1
        fi
    done
    printf '%s\n' "$backup_dir"
}

validate_server_config() {
    local config_dir="$1"
    local TELEGO_CONFIG="$config_dir/config.toml"
    local COMPOSE_FILE="$config_dir/compose.yaml"
    local ENV_FILE="$config_dir/.env"
    require_setup
    compose config --quiet && compose config --images "$CONTAINER_NAME" >/dev/null
}

rollback_server_config() {
    local backup_dir="$1" previous_state="$2" file
    for file in config.toml compose.yaml .env; do
        if [ -f "$backup_dir/$file" ]; then
            cp -p "$backup_dir/$file" "$CONFIG_DIR/$file" || return 1
        else
            rm -f "$CONFIG_DIR/$file" || return 1
        fi
    done

    load_env
    case "$previous_state" in
        true) up_and_check || return 1 ;;
        false) compose create --force-recreate "$CONTAINER_NAME" >/dev/null || return 1 ;;
        missing)
            if check_container_exists; then
                docker rm -f "$CONTAINER_NAME" >/dev/null || return 1
            fi
            ;;
    esac
    rm -rf "$backup_dir"
}

# Установка

ensure_caddy_network() {
    if docker network inspect "$CADDY_NETWORK" &>/dev/null; then
        echo -e "  ${YELLOW}Сеть '${CADDY_NETWORK}' уже существует.${NC}"
    else
        read -rp "Создать Docker-сеть '${CADDY_NETWORK}'? [y/n]: " create_net || create_net="n"
        if [[ "$create_net" =~ ^[Yy]$ ]]; then
            docker network create "$CADDY_NETWORK" --ipv6
            echo -e "  ${GREEN}Сеть '${CADDY_NETWORK}' создана.${NC}"
        else
            echo -e "  ${YELLOW}Сеть не создана — она потребуется при setup.${NC}"
        fi
    fi
    local running_images
    running_images=$(docker ps --format '{{.Image}}' 2>/dev/null || true)
    if ! grep -q caddy-docker-proxy <<< "$running_images"; then
        echo -e "  ${YELLOW}Внимание: Caddy (caddy-docker-proxy) не запущен.${NC}"
        echo -e "  ${YELLOW}Он должен публиковать порты 80/443 и быть в сети '${CADDY_NETWORK}'.${NC}"
        echo -e "  ${YELLOW}Минимальная настройка — в README, раздел «Требования».${NC}"
    fi
}

install_manager_binary() {
    local tmp source_file origin
    tmp=$(mktemp "${BINARY_PATH}.XXXXXX") || {
        echo -e "${RED}Не удалось создать временный файл рядом с ${BINARY_PATH}.${NC}"
        return 1
    }

    source_file="${BASH_SOURCE[0]:-}"
    if [ ! -f "$source_file" ] && [ -f "$0" ]; then
        source_file="$0"
    fi
    if [ -f "$source_file" ]; then
        origin="локального файла"
        if ! cp "$source_file" "$tmp"; then
            rm -f "$tmp"
            return 1
        fi
    else
        origin="репозитория"
        if ! curl -fsSL --max-time 15 "$SCRIPT_URL" -o "$tmp"; then
            rm -f "$tmp"
            return 1
        fi
    fi

    if [ -s "$tmp" ] && bash -n "$tmp" && chmod 755 "$tmp" && mv -f "$tmp" "$BINARY_PATH"; then
        echo -e "  ${GREEN}Скрипт установлен из ${origin}: ${BINARY_PATH}${NC}"
        return 0
    fi

    rm -f "$tmp"
    echo -e "${RED}Не удалось обновить бинарник. Повторите install при доступном репозитории.${NC}"
    return 1
}

write_compose_file() {
    cat > "$COMPOSE_FILE" <<EOF
# Примеры лейблов для своего сайта — в README репозитория.
name: mtproto-manager

services:
  ${CONTAINER_NAME}:
    image: ${DOCKER_IMAGE}
    container_name: ${CONTAINER_NAME}
    restart: unless-stopped
    command: ["run", "-c", "/config.toml"]
    ports:
      - "\${MTPROXY_PORT}:4433"
    volumes:
      - ./config.toml:/config.toml:ro
    extra_hosts:
      - "\${DOMAIN}:host-gateway"
    networks:
      - ${CADDY_NETWORK}
    labels:
      caddy: "\${DOMAIN}"
      caddy.reverse_proxy: "{{upstreams 8080}}"
      caddy.reverse_proxy.request_buffers: "16MB"
      caddy.reverse_proxy.@fallback.status: "418 419"
      caddy.reverse_proxy.handle_response: "@fallback"
      caddy.reverse_proxy.handle_response.header: "Content-Type text/html"
      caddy.reverse_proxy.handle_response.respond: '"<!doctype html><html><head><title>Welcome!</title></head><body><h1>Welcome!</h1></body></html>" 200'
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

networks:
  ${CADDY_NETWORK}:
    external: true
EOF
}

install_script() {
    check_root
    echo -e "${BOLD}${BLUE}╔══════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${BLUE}║     Установка mtproto-manager        ║${NC}"
    echo -e "${BOLD}${BLUE}╚══════════════════════════════════════╝${NC}"
    echo ""

    echo -e "${CYAN}[1/5] Проверка Docker...${NC}"
    if ! command -v docker &>/dev/null; then
        echo -e "  Установка Docker..."
        curl -fsSL https://get.docker.com | sh
        systemctl enable --now docker
        echo -e "  ${GREEN}Docker установлен и запущен.${NC}"
    else
        echo -e "  ${YELLOW}Docker уже установлен.${NC}"
        if ! docker info &>/dev/null; then
            systemctl start docker
            echo -e "  ${GREEN}Docker запущен.${NC}"
        fi
    fi
    check_docker_compose

    echo -e "${CYAN}[2/5] Проверка qrencode...${NC}"
    if ! command -v qrencode &>/dev/null; then
        echo -e "  Установка qrencode..."
        if command -v apt-get &>/dev/null; then
            if ! apt-get update -qq || ! apt-get install -y qrencode; then
                echo -e "  ${YELLOW}Не удалось установить qrencode. QR-коды недоступны.${NC}"
            fi
        elif command -v yum &>/dev/null; then
            if ! yum install -y qrencode; then
                echo -e "  ${YELLOW}Не удалось установить qrencode. QR-коды недоступны.${NC}"
            fi
        else
            echo -e "  ${YELLOW}Предупреждение: менеджер пакетов не найден. QR-коды недоступны.${NC}"
        fi
    else
        echo -e "  ${YELLOW}qrencode уже установлен.${NC}"
    fi

    echo -e "${CYAN}[3/5] Проверка сети '${CADDY_NETWORK}'...${NC}"
    ensure_caddy_network

    echo -e "${CYAN}[4/5] Файлы конфигурации...${NC}"
    mkdir -p "$CONFIG_DIR"
    chmod 700 "$CONFIG_DIR"
    if [ -f "$COMPOSE_FILE" ]; then
        echo -e "  ${YELLOW}Существующий compose.yaml сохранён.${NC}"
    else
        write_compose_file
        echo -e "  ${GREEN}Создан: ${COMPOSE_FILE}${NC}"
    fi
    if [ -f "$ENV_FILE" ]; then
        echo -e "  ${YELLOW}Существующий ${ENV_FILE} сохранён.${NC}"
    else
        {
            echo "DOMAIN="
            echo "MTPROXY_PORT=${DEFAULT_MTPROXY_PORT}"
        } > "$ENV_FILE"
        echo -e "  ${GREEN}Создан: ${ENV_FILE}${NC}"
    fi
    chmod 600 "$ENV_FILE"

    echo -e "${CYAN}[5/5] Установка бинарника в $BINARY_PATH...${NC}"
    install_manager_binary || exit 1

    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║      Установка завершена!            ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  Справка:      ${CYAN}mtproto-manager help${NC}"
    echo -e "  Настройка:    ${CYAN}mtproto-manager setup${NC}"
    echo ""
    read -rp "Настроить прокси сейчас? [y/n]: " setup_now || return 0
    if [[ "$setup_now" =~ ^[Yy]$ ]]; then
        setup_server
    fi
}

# Настройка сервера

validate_domain() {
    local domain="$1" label
    local labels=()
    [[ ${#domain} -le 253 && "$domain" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]] || return 1
    [[ ! "$domain" =~ ^[0-9.]+$ ]] || return 1
    IFS='.' read -ra labels <<< "$domain"
    for label in "${labels[@]}"; do
        [ "${#label}" -le 63 ] || return 1
    done
    # Telegram WEB не принимает числовую последнюю DNS-метку, включая 0x-форму.
    label="${domain##*.}"
    [[ ! "${label,,}" =~ ^([0-9]+|0x[0-9a-f]*)$ ]]
}

validate_mtproxy_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]{1,5}$ ]] || return 1
    port=$((10#$port))
    (( port >= 1 && port <= 65535 && port != 80 && port != 443 )) || return 1
    printf '%s' "$port"
}

write_server_config() {
    local toml_subnets="$1" first_user="$2" first_secret="$3"
    if [ ! -f "$COMPOSE_FILE" ]; then
        write_compose_file || return 1
    fi
    if [ ! -f "$TELEGO_CONFIG" ]; then
        cat > "$TELEGO_CONFIG" <<'EOF' || return 1
# Пользователей меняйте командами mtproto-manager.
# После ручных изменений: mtproto-manager restart

[general]
log-level = "info"

[secrets]

[tls-fronting]

[web-proxy]

[performance]
prefer-ip = "prefer-ipv4"
EOF
    fi

    # Меняем только параметры, которыми управляет setup; остальные сохраняем.
    # shellcheck disable=SC2016
    rewrite_telego_config '
        BEGIN {
            table[1]="general"; key[1]="bind-to"; value[1]="\"" mt_listen "\""
            table[2]="tls-fronting"; key[2]="mask-host"; value[2]="\"" domain "\""
            table[3]="web-proxy"; key[3]="enabled"; value[3]="true"
            table[4]="web-proxy"; key[4]="hostname"; value[4]="\"" domain "\""
            table[5]="web-proxy"; key[5]="bind-to"; value[5]="\"" web_listen "\""
            table[6]="web-proxy"; key[6]="trusted-proxy-cidrs"; value[6]="[" subnets "]"
            for (i=1; i<=6; i++) setting[table[i], key[i]]=i
        }
        function flush(s, i) {
            for (i=1; i<=6; i++) if (table[i] == s && !written[i]) {
                print key[i] " = " value[i]; written[i]=1
            }
            if (s == "web-proxy" && !carrier) print "carrier = \"websocket\""
        }
        function array_delta(line) {
            gsub(/"([^"\\]|\\.)*"|\047[^\047]*\047/, "", line)
            sub(/#.*/, "", line)
            return gsub(/\[/, "", line) - gsub(/\]/, "", line)
        }
        skip_array {
            skip_array += array_delta($0)
            next
        }
        /^[[:space:]]*\[/ {
            flush(section)
            section=$0; sub(/^[[:space:]]*\[/, "", section); sub(/\].*$/, "", section)
            present[section]=1
            print; next
        }
        /^[[:space:]]*[A-Za-z0-9_-]+[[:space:]]*=/ {
            name=$0; sub(/[[:space:]]*=.*/, "", name); sub(/^[[:space:]]*/, "", name)
            if (section == "web-proxy" && name == "carrier") carrier=1
            id=setting[section, name]
            if (id) {
                print key[id] " = " value[id]; written[id]=1
                if (key[id] == "trusted-proxy-cidrs") skip_array=array_delta($0)
                next
            }
        }
        { print }
        END {
            if (skip_array) exit 1
            flush(section)
            for (i=1; i<=6; i++) if (!present[table[i]]) {
                print "\n[" table[i] "]"; present[table[i]]=1; flush(table[i])
            }
        }
    ' -v domain="$DOMAIN" -v subnets="$toml_subnets" \
        -v mt_listen="$TELEGO_MTPROXY_LISTEN" -v web_listen="$TELEGO_WEB_LISTEN" || return 1

    if [ -n "$first_user" ]; then
        secret_add "$first_user" "$first_secret" || return 1
    fi
    write_env_file
}

setup_server() {
    check_root
    check_docker
    if ! command -v ss &>/dev/null; then
        echo -e "${RED}Ошибка: не найдена команда ss. Установите пакет iproute2.${NC}"
        exit 1
    fi
    load_env

    local arg_domain="${1:-}"
    local arg_port="${2:-}"
    local old_domain="$DOMAIN"
    local port_input

    echo -e "${BOLD}${BLUE}=== Настройка сервера ===${NC}"
    echo ""

    if [ -n "$arg_domain" ]; then
        DOMAIN="$arg_domain"
    else
        echo -e "Текущий домен: ${CYAN}${DOMAIN:-не задан}${NC}"
        echo -e "  Домен должен указывать (A-запись) на IP этого сервера."
        echo -e "  Через него работает WEB-прокси (https://<домен>) и маскируется MTProxy."
        echo ""
        read -rp "Введите домен: " input_domain
        DOMAIN="$input_domain"
    fi

    if [ -z "$DOMAIN" ]; then
        echo -e "${RED}Ошибка: домен обязателен.${NC}"
        exit 1
    fi
    if ! validate_domain "$DOMAIN"; then
        echo -e "${RED}Ошибка: '${DOMAIN}' не похоже на домен (без схемы и порта).${NC}"
        exit 1
    fi
    DOMAIN="${DOMAIN,,}"

    local resolved_ip server_ip
    resolved_ip=$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1; exit}' || true)
    server_ip=$(get_ip)
    if [ -z "$resolved_ip" ]; then
        echo -e "  ${YELLOW}Внимание: домен не резолвится — Caddy не выпустит сертификат.${NC}"
    elif [ -n "$server_ip" ] && [ "$resolved_ip" != "$server_ip" ]; then
        echo -e "  ${YELLOW}Внимание: домен указывает на ${resolved_ip}, а IP сервера — ${server_ip}.${NC}"
    fi

    if [ -n "$arg_port" ]; then
        if ! MTPROXY_PORT=$(validate_mtproxy_port "$arg_port"); then
            echo -e "${RED}Ошибка: укажите порт от 1 до 65535, кроме 80 и 443.${NC}"
            exit 1
        fi
        if ! is_port_available_for_telego "$MTPROXY_PORT"; then
            echo -e "${RED}Ошибка: порт ${MTPROXY_PORT} занят.${NC}"
            exit 1
        fi
    else
        local port_hint="${MTPROXY_PORT:-$DEFAULT_MTPROXY_PORT}"
        echo ""
        echo -e "Текущий MTProxy-порт: ${CYAN}${MTPROXY_PORT:-не задан}${NC}"
        echo -e "  Публичный порт для MTProto-клиентов (не 80/443 — они заняты Caddy)."
        read -rp "Порт [${port_hint}]: " input_port
        if [ -n "$input_port" ]; then
            port_input="$input_port"
        else
            port_input="$port_hint"
        fi
        if ! MTPROXY_PORT=$(validate_mtproxy_port "$port_input"); then
            echo -e "${RED}Ошибка: укажите порт от 1 до 65535, кроме 80 и 443.${NC}"
            exit 1
        fi
        if ! is_port_available_for_telego "$MTPROXY_PORT"; then
            MTPROXY_PORT=$(find_free_port "$(( MTPROXY_PORT + 1 ))") || exit 1
            echo -e "  ${YELLOW}Порт занят — использую ${MTPROXY_PORT}.${NC}"
        fi
    fi

    if ! docker network inspect "$CADDY_NETWORK" &>/dev/null; then
        docker network create "$CADDY_NETWORK" --ipv6
        echo -e "  ${GREEN}Сеть '${CADDY_NETWORK}' создана.${NC}"
    fi

    # Подсети сети caddy — доверенные для X-Forwarded-For
    local subnets toml_subnets s
    subnets=$(docker network inspect "$CADDY_NETWORK" \
        -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}' 2>/dev/null || true)
    toml_subnets=""
    for s in $subnets; do
        [ -z "$s" ] && continue
        if [ -n "$toml_subnets" ]; then
            toml_subnets+=", "
        fi
        toml_subnets+="\"$s\""
    done
    if [ -z "$toml_subnets" ]; then
        echo -e "${RED}Ошибка: не удалось определить подсети сети ${CADDY_NETWORK}.${NC}"
        exit 1
    fi

    # Без активного секрета telego не запустится — создаём первого пользователя.
    local first_user="" first_secret="" input_first
    if [ "$(active_secret_count)" -eq 0 ]; then
        if [ -n "$arg_domain" ]; then
            first_user="user1"
            local user_number=1
            while [ -n "$(get_secret_entry "$first_user")" ]; do
                (( user_number++ )) || true
                first_user="user${user_number}"
            done
        else
            echo ""
            echo -e "  telego требует минимум одного пользователя."
            read -rp "Имя первого пользователя [user1]: " input_first
            first_user="${input_first:-user1}"
        fi
        if ! validate_username "$first_user"; then
            echo -e "${RED}Ошибка: имя может содержать только латинские буквы, цифры, '_' и '-'.${NC}"
            exit 1
        fi
        if [ -n "$(get_secret_entry "$first_user")" ]; then
            echo -e "${RED}Ошибка: пользователь '${first_user}' уже существует, но заблокирован.${NC}"
            echo -e "Разблокируйте его или укажите другое имя."
            exit 1
        fi
        echo -e "${CYAN}Генерация секрета для домена ${DOMAIN}...${NC}"
        if ! first_secret=$(generate_secret); then
            echo -e "${RED}Ошибка: не удалось сгенерировать секрет. Проверьте Docker и image в ${COMPOSE_FILE}.${NC}"
            exit 1
        fi
    fi

    if [ -n "$old_domain" ] && [ "$old_domain" != "$DOMAIN" ] && [ -n "$(list_secrets)" ]; then
        echo ""
        echo -e "  ${YELLOW}Внимание: домен изменён — ссылки у всех пользователей изменятся.${NC}"
        echo -e "  ${YELLOW}Раздайте новые: mtproto-manager show-user <имя>${NC}"
    fi

    local backup_dir previous_state
    mkdir -p "$CONFIG_DIR"
    chmod 700 "$CONFIG_DIR"
    backup_dir=$(backup_server_config) || exit 1
    previous_state=$(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null || echo missing)
    if ! write_server_config "$toml_subnets" "$first_user" "$first_secret"; then
        rollback_server_config "$backup_dir" "$previous_state" \
            || echo -e "${RED}Не удалось выполнить откат. Резервная копия: ${backup_dir}${NC}" >&2
        echo -e "${RED}Ошибка: не удалось записать конфигурацию.${NC}"
        exit 1
    fi

    echo ""
    echo -e "${CYAN}Запуск контейнера ${CONTAINER_NAME}...${NC}"
    if ! up_and_check; then
        rollback_server_config "$backup_dir" "$previous_state" \
            || echo -e "${RED}Не удалось выполнить откат. Резервная копия: ${backup_dir}${NC}" >&2
        print_telego_failure
        exit 1
    fi
    rm -rf "$backup_dir"
    echo -e "  ${GREEN}✓ ${CONTAINER_NAME} запущен.${NC}"

    echo -e "${CYAN}Проверка https://${DOMAIN}/...${NC}"
    if curl -fs --max-time 20 "https://${DOMAIN}/" >/dev/null 2>&1; then
        echo -e "  ${GREEN}✓ Сайт-заглушка доступна по https://${DOMAIN}${NC}"
    else
        echo -e "  ${YELLOW}! Заглушка пока недоступна (сертификат может выпускаться до минуты).${NC}"
        echo -e "  ${YELLOW}  Проверьте позже: curl https://${DOMAIN}/${NC}"
    fi

    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║        Настройка завершена!          ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  Домен:         ${CYAN}${DOMAIN}${NC}"
    echo -e "  WEB-прокси:    ${CYAN}https://${DOMAIN}${NC}"
    echo -e "  MTProxy-порт:  ${CYAN}${MTPROXY_PORT}${NC}"
    echo ""
    if [ -n "$first_user" ]; then
        echo -e "  Первый пользователь: ${BOLD}${first_user}${NC}"
        echo -e "  Секрет: ${CYAN}${first_secret}${NC}"
        echo ""
        print_user_links "$first_secret"
        print_qr "$first_secret"
        echo ""
        echo -e "  Новый пользователь:     ${CYAN}mtproto-manager add-user <имя>${NC}"
    else
        echo -e "  Пользователи и ссылки:  ${CYAN}mtproto-manager list-users${NC}"
        echo -e "  Новый пользователь:     ${CYAN}mtproto-manager add-user <имя>${NC}"
    fi
    echo ""
}

# Управление пользователями

validate_username() {
    [[ "$1" =~ ^[A-Za-z0-9_-]+$ ]]
}

require_username() {
    local username="$1" cmd="$2"
    if [ -z "$username" ]; then
        echo -e "${RED}Ошибка: укажите имя пользователя.${NC}" >&2
        echo "Использование: mtproto-manager ${cmd} <имя>" >&2
        exit 1
    fi
    if ! validate_username "$username"; then
        echo -e "${RED}Ошибка: имя может содержать только латинские буквы, цифры, '_' и '-'.${NC}" >&2
        exit 1
    fi
}

add_user() {
    check_root
    check_docker
    require_setup

    local username="${1:-}"
    require_username "$username" add-user
    if [ -n "$(get_secret_entry "$username")" ]; then
        echo -e "${RED}Пользователь '${username}' уже существует.${NC}"
        exit 1
    fi

    echo -e "${CYAN}Генерация секрета для домена ${DOMAIN}...${NC}"
    local secret
    if ! secret=$(generate_secret); then
        echo -e "${RED}Ошибка: не удалось сгенерировать секрет. Проверьте Docker и image в ${COMPOSE_FILE}.${NC}"
        exit 1
    fi

    if ! apply_secret_change add "$username" "$secret"; then
        exit 1
    fi

    echo ""
    echo -e "${GREEN}Пользователь '${username}' создан.${NC}"
    echo -e "  Секрет: ${CYAN}${secret}${NC}"
    echo ""
    print_user_links "$secret"
    print_qr "$secret"
    echo ""
}

remove_user() {
    check_root
    check_docker
    require_setup

    local username="${1:-}"
    require_username "$username" remove-user
    local entry ustatus
    entry=$(require_secret_entry "$username") || exit 1
    IFS=':' read -r _ _ ustatus <<< "$entry"
    if [ "$ustatus" = "active" ] && [ "$(active_secret_count)" -le 1 ]; then
        echo -e "${RED}Нельзя удалить последнего активного пользователя: telego требует минимум один секрет.${NC}"
        echo -e "Сначала добавьте другого пользователя."
        exit 1
    fi

    if ! apply_secret_change remove "$username"; then
        exit 1
    fi
    echo -e "${GREEN}Пользователь '${username}' удалён.${NC}"
}

list_users() {
    check_root
    require_setup

    local entries
    entries=$(list_secrets)
    if [ -z "$entries" ]; then
        echo -e "${YELLOW}Пользователей нет. Добавьте: mtproto-manager add-user <имя>${NC}"
        return
    fi

    local container_state
    if container_is_running "$CONTAINER_NAME"; then
        container_state="${GREEN}работает${NC}"
    else
        container_state="${RED}остановлен${NC}"
    fi

    echo -e "${BOLD}${BLUE}=== Пользователи ===${NC}"
    echo -e "Домен: ${CYAN}${DOMAIN}${NC} | MTProxy-порт: ${CYAN}${MTPROXY_PORT}${NC} | контейнер: [${container_state}]"
    echo ""

    local line uname usecret ustatus status
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        IFS=':' read -r uname usecret ustatus <<< "$line"
        if [ "$ustatus" = "blocked" ]; then
            status="${YELLOW}заблокирован${NC}"
        else
            status="${GREEN}активен${NC}"
        fi
        echo -e "  ${BOLD}${uname}${NC} [${status}]"
        if [ "$ustatus" = "active" ]; then
            echo -e "    WEB-прокси: ${CYAN}https://t.me/webproxy?server=${DOMAIN}&secret=${usecret}${NC}"
        fi
        echo ""
    done <<< "$entries"
}

show_user() {
    check_root
    require_setup

    local username="${1:-}"
    require_username "$username" show-user

    local entry
    entry=$(require_secret_entry "$username") || exit 1

    local usecret ustatus
    IFS=':' read -r _ usecret ustatus <<< "$entry"

    echo -e "${BOLD}${BLUE}=== Пользователь: ${username} ===${NC}"
    echo ""
    if [ "$ustatus" = "blocked" ]; then
        echo -e "  ${YELLOW}Заблокирован — разблокировать: mtproto-manager unblock-user ${username}${NC}"
        echo ""
    fi
    echo -e "  Секрет: ${CYAN}${usecret}${NC}"
    echo -e "  Домен:   ${CYAN}${DOMAIN}${NC}"
    echo ""
    print_user_links "$usecret"
    print_qr "$usecret"
    echo ""
}

block_user() {
    check_root
    check_docker
    require_setup

    local username="${1:-}"
    require_username "$username" block-user

    local entry ustatus
    entry=$(require_secret_entry "$username") || exit 1
    IFS=':' read -r _ _ ustatus <<< "$entry"
    if [ "$ustatus" = "blocked" ]; then
        echo -e "${YELLOW}Пользователь '${username}' уже заблокирован.${NC}"
        return
    fi
    if [ "$(active_secret_count)" -le 1 ]; then
        echo -e "${RED}Нельзя заблокировать последнего активного пользователя: telego требует минимум один секрет.${NC}"
        echo -e "Сначала добавьте другого пользователя."
        exit 1
    fi

    if ! apply_secret_change block "$username"; then
        exit 1
    fi
    echo -e "${YELLOW}Пользователь '${username}' заблокирован (секрет сохранён в конфиге).${NC}"
}

unblock_user() {
    check_root
    check_docker
    require_setup

    local username="${1:-}"
    require_username "$username" unblock-user

    local entry ustatus
    entry=$(require_secret_entry "$username") || exit 1
    IFS=':' read -r _ _ ustatus <<< "$entry"
    if [ "$ustatus" = "active" ]; then
        echo -e "${YELLOW}Пользователь '${username}' не заблокирован.${NC}"
        return
    fi

    if ! apply_secret_change unblock "$username"; then
        exit 1
    fi
    echo -e "${GREEN}Пользователь '${username}' разблокирован.${NC}"
}

export_users() {
    check_root
    require_setup

    local export_file export_base tmp suffix=1
    export_base="mtproto-manager_$(date +%Y%m%d_%H%M%S)"
    tmp=$(mktemp "./.${export_base}.XXXXXX") || return 1
    if ! tar -czf "$tmp" -C "$CONFIG_DIR" config.toml compose.yaml .env; then
        rm -f "$tmp"
        echo -e "${RED}Ошибка: не удалось создать архив конфигурации.${NC}" >&2
        return 1
    fi

    export_file="${export_base}.tar.gz"
    # ln публикует готовый архив без перезаписи файлов или символических ссылок.
    while ! ln -T "$tmp" "$export_file" 2>/dev/null; do
        if [ ! -e "$export_file" ] && [ ! -L "$export_file" ]; then
            rm -f "$tmp"
            echo -e "${RED}Ошибка: не удалось сохранить архив ${export_file}.${NC}" >&2
            return 1
        fi
        export_file="${export_base}_${suffix}.tar.gz"
        (( suffix++ )) || true
    done
    rm -f "$tmp"
    echo -e "${GREEN}Конфигурация экспортирована: $(pwd)/${export_file}${NC}"
}

import_users() {
    check_root
    check_docker

    local import_file="${1:-}"
    if [ -z "$import_file" ]; then
        echo -e "${RED}Ошибка: укажите файл.${NC}"
        echo "Использование: mtproto-manager import <файл.tar.gz>"
        exit 1
    fi
    if [ ! -f "$import_file" ]; then
        echo -e "${RED}Файл не найден: ${import_file}${NC}"
        exit 1
    fi
    local archive_files member
    local archive_members=()
    local -A seen_members=()
    if ! archive_files=$(tar -tzf "$import_file" 2>/dev/null); then
        echo -e "${RED}Ошибка: архив повреждён или имеет неверный формат.${NC}"
        exit 1
    fi
    if ! grep -qx 'config.toml' <<< "$archive_files"; then
        echo -e "${RED}Ошибка: в архиве нет config.toml (это бэкап mtproto-manager?).${NC}"
        exit 1
    fi
    while IFS= read -r member; do
        [ -z "$member" ] && continue
        case "$member" in
            config.toml|compose.yaml|.env)
                if [ -n "${seen_members[$member]:-}" ]; then
                    echo -e "${RED}Ошибка: повторяющийся файл в архиве: ${member}${NC}"
                    exit 1
                fi
                seen_members[$member]=1
                archive_members+=("$member")
                ;;
            *)
                echo -e "${RED}Ошибка: недопустимый файл в архиве: ${member}${NC}"
                exit 1
                ;;
        esac
    done <<< "$archive_files"

    if ! tar -tvzf "$import_file" 2>/dev/null \
        | awk 'substr($1, 1, 1) != "-" { bad=1 } END { exit bad }'; then
        echo -e "${RED}Ошибка: архив должен содержать только обычные файлы, без ссылок и каталогов.${NC}"
        exit 1
    fi

    local tmp_dir file backup_dir previous_state
    tmp_dir=$(mktemp -d) || exit 1
    if ! tar -xzf "$import_file" -C "$tmp_dir" --no-same-owner --no-same-permissions -- "${archive_members[@]}" 2>/dev/null; then
        rm -rf "$tmp_dir"
        echo -e "${RED}Ошибка: не удалось безопасно распаковать архив.${NC}"
        exit 1
    fi

    # Архив только с config.toml допустим, если сервер уже настроен.
    for file in compose.yaml .env; do
        if [ ! -f "$tmp_dir/$file" ] && ! cp "$CONFIG_DIR/$file" "$tmp_dir/$file" 2>/dev/null; then
            rm -rf "$tmp_dir"
            echo -e "${RED}Ошибка: для первого импорта архив должен содержать ${file}.${NC}"
            exit 1
        fi
    done
    if [ "$(TELEGO_CONFIG="$tmp_dir/config.toml" active_secret_count)" -eq 0 ]; then
        rm -rf "$tmp_dir"
        echo -e "${RED}Ошибка: в импортируемом config.toml нет активных пользователей.${NC}"
        exit 1
    fi
    if ! ( validate_server_config "$tmp_dir" ); then
        rm -rf "$tmp_dir"
        echo -e "${RED}Ошибка: импортируемая конфигурация невалидна.${NC}"
        exit 1
    fi

    mkdir -p "$CONFIG_DIR"
    chmod 700 "$CONFIG_DIR"
    backup_dir=$(backup_server_config) || { rm -rf "$tmp_dir"; exit 1; }
    previous_state=$(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null || echo missing)
    if ! cp "$tmp_dir/config.toml" "$TELEGO_CONFIG" \
        || ! cp "$tmp_dir/compose.yaml" "$COMPOSE_FILE" \
        || ! cp "$tmp_dir/.env" "$ENV_FILE" \
        || ! chmod 600 "$TELEGO_CONFIG" "$COMPOSE_FILE" "$ENV_FILE"; then
        rm -rf "$tmp_dir"
        rollback_server_config "$backup_dir" "$previous_state" \
            || echo -e "${RED}Не удалось выполнить откат. Резервная копия: ${backup_dir}${NC}" >&2
        echo -e "${RED}Ошибка: не удалось записать конфигурацию.${NC}"
        exit 1
    fi
    rm -rf "$tmp_dir"
    load_env

    echo -e "${CYAN}Запуск ${CONTAINER_NAME}...${NC}"
    if ! up_and_check; then
        rollback_server_config "$backup_dir" "$previous_state" \
            || echo -e "${RED}Не удалось выполнить откат. Резервная копия: ${backup_dir}${NC}" >&2
        print_telego_failure
        exit 1
    fi
    rm -rf "$backup_dir"
    echo -e "${GREEN}Конфигурация импортирована, прокси запущен.${NC}"
    echo -e "Ссылки пользователей: ${CYAN}mtproto-manager list-users${NC}"
}

# Управление контейнером

require_container() {
    if ! check_container_exists; then
        echo -e "${RED}Ошибка: контейнер '${CONTAINER_NAME}' не найден. Сначала: mtproto-manager setup${NC}"
        exit 1
    fi
}

start_all() {
    check_root
    check_docker
    require_setup
    require_container
    echo -e "${CYAN}Запуск ${CONTAINER_NAME}...${NC}"
    compose start "$CONTAINER_NAME" >/dev/null
    if ! wait_telego_started; then
        print_telego_failure
        exit 1
    fi
    echo -e "  ${GREEN}✓ ${CONTAINER_NAME} запущен.${NC}"
}

stop_all() {
    check_root
    check_docker
    require_setup
    require_container
    echo -e "${CYAN}Остановка ${CONTAINER_NAME}...${NC}"
    compose stop "$CONTAINER_NAME" >/dev/null
    echo -e "  ${YELLOW}✓ ${CONTAINER_NAME} остановлен.${NC}"
}

restart_all() {
    check_root
    check_docker
    require_setup
    require_container
    echo -e "${CYAN}Перезапуск ${CONTAINER_NAME}...${NC}"
    if ! restart_and_check; then
        print_telego_failure
        exit 1
    fi
    echo -e "  ${GREEN}✓ ${CONTAINER_NAME} перезапущен.${NC}"
}

status_all() {
    check_root
    check_docker
    require_setup

    echo -e "${BOLD}${BLUE}=== Статус ===${NC}"
    echo ""
    if check_container_exists; then
        compose ps
    else
        echo -e "  ${RED}Контейнер '${CONTAINER_NAME}' не найден. Сначала: mtproto-manager setup${NC}"
    fi

    echo ""
    local entries active=0 blocked=0 line ustatus
    entries=$(list_secrets)
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        IFS=':' read -r _ _ ustatus <<< "$line"
        if [ "$ustatus" = "blocked" ]; then
            (( blocked++ )) || true
        else
            (( active++ )) || true
        fi
    done <<< "$entries"
    echo -e "  Пользователи: ${GREEN}${active} активных${NC}, ${YELLOW}${blocked} заблокированных${NC}"
    echo -e "  Домен:        ${CYAN}${DOMAIN}${NC}"
    echo -e "  WEB-прокси:   ${CYAN}https://${DOMAIN}${NC}"
    echo -e "  MTProxy-порт: ${CYAN}${MTPROXY_PORT}${NC}"
    echo ""
}

show_traffic() {
    check_root
    check_docker
    require_container
    echo -e "${CYAN}Трафик ${CONTAINER_NAME} (Ctrl+C для выхода):${NC}"
    echo ""
    docker stats "$CONTAINER_NAME"
}

update_image() {
    check_root
    check_docker
    require_setup

    local image
    image=$(get_telego_image) || exit 1
    echo -e "${CYAN}Обновление образа ${image}...${NC}"
    compose pull "$CONTAINER_NAME"
    echo -e "${CYAN}Пересоздание ${CONTAINER_NAME}...${NC}"
    if ! up_and_check; then
        print_telego_failure
        exit 1
    fi
    echo -e "${GREEN}✓ Образ обновлён, контейнер пересоздан.${NC}"
    echo ""
    echo -e "  ${YELLOW}Образ задаётся полем image в секции telego файла ${COMPOSE_FILE}.${NC}"
}

# Удаление

uninstall_script() {
    check_root

    echo -e "${RED}${BOLD}=== Удаление mtproto-manager ===${NC}"
    echo ""
    read -rp "Вы уверены? Контейнер и вся конфигурация будут удалены. [y/N]: " confirm
    [[ "${confirm,,}" != "y" ]] && echo "Отменено." && return

    check_docker

    echo -e "${CYAN}Остановка и удаление контейнера...${NC}"
    if check_container_exists; then
        if ! docker rm -f "$CONTAINER_NAME" >/dev/null; then
            echo -e "${RED}Не удалось удалить контейнер. Конфигурация и бинарник сохранены.${NC}"
            exit 1
        fi
        echo -e "  ${YELLOW}✓ ${CONTAINER_NAME} удалён${NC}"
    else
        echo -e "  ${YELLOW}Контейнер '${CONTAINER_NAME}' не найден.${NC}"
    fi

    echo -e "${CYAN}Удаление конфигурации...${NC}"
    rm -rf "$CONFIG_DIR"
    echo -e "  ${GREEN}✓ ${CONFIG_DIR} удалён${NC}"

    echo -e "${CYAN}Удаление бинарника...${NC}"
    rm -f "$BINARY_PATH"
    echo -e "  ${GREEN}✓ ${BINARY_PATH} удалён${NC}"

    echo ""
    echo -e "${GREEN}Удаление завершено. Caddy и сеть '${CADDY_NETWORK}' не тронуты.${NC}"
}

# Справка и меню

show_help() {
    echo ""
    echo -e "${BOLD}Использование:${NC} mtproto-manager <команда> [аргументы]"
    echo ""
    echo -e "${BOLD}${BLUE}Установка и настройка:${NC}"
    echo "  install                              Установить скрипт и подготовить окружение"
    echo "  setup [домен] [порт]                 Настроить прокси (домен + публичный MTProxy-порт)"
    echo "  uninstall                            Полностью удалить скрипт и данные"
    echo ""
    echo -e "${BOLD}${BLUE}Пользователи:${NC}"
    echo "  add-user <имя>                       Создать пользователя (секрет + ссылки + QR)"
    echo "  remove-user <имя>                    Удалить пользователя"
    echo "  list-users                           Список всех пользователей"
    echo "  show-user <имя>                      Ссылки пользователя + QR-код"
    echo "  block-user <имя>                     Заблокировать (секрет сохраняется)"
    echo "  unblock-user <имя>                   Разблокировать"
    echo "  export                               Экспорт конфигурации (tar.gz)"
    echo "  import <файл>                        Импорт конфигурации"
    echo ""
    echo -e "${BOLD}${BLUE}Контейнер ${CONTAINER_NAME}:${NC}"
    echo "  start                                Запустить"
    echo "  stop                                 Остановить"
    echo "  restart                              Перезапустить"
    echo "  status                               Статус"
    echo "  show-traffic                         Трафик (docker stats)"
    echo "  update                               Обновить образ и пересоздать"
    echo ""
    echo -e "${BOLD}${BLUE}Прочее:${NC}"
    echo "  help                                 Показать эту справку"
    echo "  (без команды)                        Интерактивное меню"
    echo ""
}

show_menu() {
    local choice u f
    while true; do
        clear
        echo -e "${BOLD}${BLUE}╔══════════════════════════════════════════════════════════╗${NC}"
        echo -e "${BOLD}${BLUE}║                     mtproto-manager                      ║${NC}"
        echo -e "${BOLD}${BLUE}║          MTProxy + WEB-прокси на движке telego           ║${NC}"
        echo -e "${BOLD}${BLUE}║ https://github.com/vdistortion/mtproto-web-proxy-manager ║${NC}"
        echo -e "${BOLD}${BLUE}╚══════════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo -e "  ${CYAN}0${NC})  Выход"
        echo ""
        echo -e "${BOLD}  Пользователи${NC}"
        echo -e "  ${CYAN}1${NC}) Добавить пользователя"
        echo -e "  ${CYAN}2${NC}) Удалить пользователя"
        echo -e "  ${CYAN}3${NC}) Список пользователей"
        echo -e "  ${CYAN}4${NC}) Показать пользователя (QR)"
        echo -e "  ${CYAN}5${NC}) Заблокировать пользователя"
        echo -e "  ${CYAN}6${NC}) Разблокировать пользователя"
        echo ""
        echo -e "${BOLD}  Контейнер telego${NC}"
        echo -e "  ${CYAN}7${NC}) Запустить"
        echo -e "  ${CYAN}8${NC}) Остановить"
        echo -e "  ${CYAN}9${NC}) Перезапустить"
        echo -e "  ${CYAN}10${NC}) Статус"
        echo -e "  ${CYAN}11${NC}) Трафик"
        echo -e "  ${CYAN}12${NC}) Обновить образ"
        echo ""
        echo -e "${BOLD}  Прочее${NC}"
        echo -e "  ${CYAN}13${NC}) Настройка сервера (setup)"
        echo -e "  ${CYAN}14${NC}) Экспорт конфигурации"
        echo -e "  ${CYAN}15${NC}) Импорт конфигурации"
        echo -e "  ${CYAN}16${NC}) Удалить скрипт и все данные"
        echo ""
        read -rp "  Выбор: " choice || return 0
        [ "$choice" = "0" ] && return 0

        # Запускаем команду отдельно, чтобы её exit не закрывал меню.
        set +e
        (
            set -e
            case "$choice" in
                1|2|4|5|6) read -rp "  Имя пользователя: " u ;;
                15) read -rp "  Файл для импорта: " f ;;
            esac
            case "$choice" in
                1) main add-user "$u" ;;
                2) main remove-user "$u" ;;
                3) main list-users ;;
                4) main show-user "$u" ;;
                5) main block-user "$u" ;;
                6) main unblock-user "$u" ;;
                7)  main start ;;
                8)  main stop ;;
                9)  main restart ;;
                10) main status ;;
                11) main show-traffic ;;
                12) main update ;;
                13) main setup ;;
                14) main export ;;
                15) main import "$f" ;;
                16) main uninstall ;;
                *) echo -e "  ${RED}Неверный выбор.${NC}"; sleep 1 ;;
            esac
        )
        set -e
        if [ "$choice" = "16" ] && [ ! -f "$BINARY_PATH" ]; then
            return 0
        fi
        read -rp "  Нажмите Enter..." || return 0
    done
}

# Точка входа

main() (
    local cmd="${1:-}"
    shift || true

    # Блокировка снимается при выходе из этого subshell, даже при ошибке команды.
    case "$cmd" in
        install|setup|uninstall|add-user|remove-user|block-user|unblock-user|export|import|start|stop|restart|update)
            check_root
            if ! command -v flock &>/dev/null; then
                echo -e "${RED}Ошибка: не найдена команда flock. Установите пакет util-linux.${NC}" >&2
                exit 1
            fi
            umask 077
            exec 9>"$LOCK_FILE" || exit 1
            if ! flock -n 9; then
                echo -e "${YELLOW}Другая управляющая команда уже выполняется. Повторите позже.${NC}" >&2
                exit 1
            fi
            ;;
    esac

    case "$cmd" in
        install)
            # При curl | bash команды read должны читать терминал, а не код скрипта.
            if { true </dev/tty; } 2>/dev/null; then
                install_script </dev/tty
            else
                install_script
            fi
            ;;
        setup)                setup_server "$@" ;;
        uninstall)            uninstall_script ;;
        add-user)             add_user "$@" ;;
        remove-user)          remove_user "$@" ;;
        list-users)           list_users ;;
        show-user)            show_user "$@" ;;
        block-user)           block_user "$@" ;;
        unblock-user)         unblock_user "$@" ;;
        export)               export_users ;;
        import)               import_users "$@" ;;
        start)                start_all ;;
        stop)                 stop_all ;;
        restart)              restart_all ;;
        status)               status_all ;;
        show-traffic)         show_traffic ;;
        update)               update_image ;;
        help|--help|-h)       show_help ;;
        "")                   show_menu ;;
        *)
            echo -e "${RED}Неизвестная команда: ${cmd}${NC}"
            show_help
            exit 1
            ;;
    esac
)

if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
    main "$@"
fi
