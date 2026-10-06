#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/mtproto-manager.sh"
check_docker

CONTAINER_NAME="mtproto-caddy-test-$$"
CADDY_NETWORK="${CONTAINER_NAME}-net"
CADDY_NAME="${CONTAINER_NAME}-caddy"
SITE_NAME="${CONTAINER_NAME}-site"
LABEL_PREFIX="mpmcheck$$"
export COMPOSE_PROJECT_NAME="$CONTAINER_NAME"
for name in "$CONTAINER_NAME" "$CADDY_NAME" "$SITE_NAME"; do
    if docker inspect --type container "$name" >/dev/null 2>&1; then exit 1; fi
done
if docker network inspect "$CADDY_NETWORK" >/dev/null 2>&1; then exit 1; fi

TEST_DIR=$(mktemp -d)
CONFIG_DIR="$TEST_DIR/config"
TELEGO_CONFIG="$CONFIG_DIR/config.toml"
COMPOSE_FILE="$CONFIG_DIR/compose.yaml"
ENV_FILE="$CONFIG_DIR/.env"
LOCK_FILE="$TEST_DIR/manager.lock"
cleanup() {
    local code=$? name
    if [ "$code" -ne 0 ]; then
        for name in response site-response.json invalid-response large-response; do
            if [ -f "$TEST_DIR/$name" ]; then
                echo "Ответ $name: $(head -c 1024 "$TEST_DIR/$name")" >&2
            fi
        done
        for name in "$CONTAINER_NAME" "$CADDY_NAME" "$SITE_NAME"; do
            docker logs --tail 30 "$name" >&2 || true
        done
    fi
    for name in "$CADDY_NAME" "$SITE_NAME" "$CONTAINER_NAME"; do
        docker rm -f "$name" >/dev/null 2>&1 || true
    done
    if docker network inspect "$CADDY_NETWORK" >/dev/null 2>&1; then
        docker network rm "$CADDY_NETWORK" >/dev/null || code=1
    fi
    rm -rf "$TEST_DIR"
    exit "$code"
}
trap cleanup EXIT

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

mkdir -p "$CONFIG_DIR"
write_compose_file
# Меняем префикс лейблов, чтобы рабочий Caddy их не подхватил.
sed -i "s|      caddy:.*|      ${LABEL_PREFIX}: \"http://\${DOMAIN}\"|; s|      caddy\.|      ${LABEL_PREFIX}.|" "$COMPOSE_FILE"
# MTProxy-порт не публикуем; Caddy будет доступен только локально.
sed -i '/^    ports:$/,/^    volumes:$/ { /^    volumes:$/!d; }' "$COMPOSE_FILE"
cat > "$CONFIG_DIR/services.yaml" <<EOF
  test_caddy:
    image: lucaslorentz/caddy-docker-proxy:2.13.1-alpine
    container_name: ${CADDY_NAME}
    command: ["docker-proxy", "--label-prefix", "${LABEL_PREFIX}", "--ingress-networks", "${CADDY_NETWORK}", "--polling-interval", "1s"]
    ports:
      - "127.0.0.1::80"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    networks:
      - ${CADDY_NETWORK}
  site:
    image: node:24-alpine
    container_name: ${SITE_NAME}
    command: ["node", "/site.js"]
    volumes:
      - ./site.js:/site.js:ro
    networks:
      - ${CADDY_NETWORK}
EOF
awk -v services="$CONFIG_DIR/services.yaml" '
    /^networks:/ { while ((getline line < services) > 0) print line; close(services) }
    { print }
' "$COMPOSE_FILE" > "$COMPOSE_FILE.tmp"
mv "$COMPOSE_FILE.tmp" "$COMPOSE_FILE"
cat > "$CONFIG_DIR/site.js" <<'JS'
const http = require('node:http');
const crypto = require('node:crypto');
http.createServer((request, response) => {
  let bytes = 0;
  const hash = crypto.createHash('sha256');
  request.on('data', chunk => { bytes += chunk.length; hash.update(chunk); });
  request.on('end', () => {
    console.log('SITE_REQUEST');
    response.setHeader('Content-Type', 'application/json');
    response.end(JSON.stringify({
      method: request.method, url: request.url, host: request.headers.host,
      authorization: request.headers.authorization, cookie: request.headers.cookie,
      bytes, sha256: hash.digest('hex')
    }));
  });
}).listen(80, '0.0.0.0');
JS

port=$(find_free_port 49443)
main setup proxy.example.invalid "$port" > "$TEST_DIR/setup.log"
load_env
compose up -d test_caddy site >/dev/null
address=$(docker port "$CADDY_NAME" 80/tcp)
URL="http://${address}"

wait_response() {
    local expected="$1" path="$2" attempt status
    for ((attempt=0; attempt<60; attempt++)); do
        status=$(command curl --noproxy '*' -s --max-time 2 -o "$TEST_DIR/response" -w '%{http_code}' \
            -H "Host: $DOMAIN" "$URL$path" || true)
        if [ "$status" = "$expected" ]; then return 0; fi
        sleep 0.5
    done
    echo "Ожидался HTTP $expected для $path, получен $status" >&2
    return 1
}

wait_response 200 /
grep -q 'Welcome!' "$TEST_DIR/response"
echo "OK: сгенерированные лейблы Caddy обслуживают сайт-заглушку"

check_web_protocol() {
    local entry secret
    entry=$(get_secret_entry user1)
    IFS=: read -r _ secret _ <<< "$entry"
    # HMAC и HELLO/WELCOME соответствуют pkg/webproxy/{capability,frame}.go в telego.
    docker exec -i "$SITE_NAME" node - "$CADDY_NAME" "$DOMAIN" "$secret" <<'JS'
const http = require('node:http');
const crypto = require('node:crypto');
const assert = require('node:assert/strict');
const [hostname, domain, baseSecret] = process.argv.slice(2);
function request(method, path, headers = {}, body) {
  return new Promise((resolve, reject) => {
    const req = http.request({ hostname, port: 80, method, path, headers: { Host: domain, ...headers } }, res => {
      const chunks = [];
      res.on('data', chunk => chunks.push(chunk));
      res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, body: Buffer.concat(chunks) }));
      res.on('error', reject);
    });
    req.on('error', reject);
    req.setTimeout(5000, () => req.destroy(new Error('HTTP timeout')));
    req.end(body);
  });
}
function upgrade(token) {
  return new Promise((resolve, reject) => {
    const key = crypto.randomBytes(16).toString('base64');
    const protocol = 'tproxy-v1.' + token;
    const req = http.request({ hostname, port: 80, path: '/api/v1/ws', headers: {
      Host: domain, Connection: 'Upgrade', Upgrade: 'websocket',
      'Sec-WebSocket-Version': '13', 'Sec-WebSocket-Key': key, 'Sec-WebSocket-Protocol': protocol
    }});
    req.on('error', reject);
    req.setTimeout(5000, () => req.destroy(new Error('WebSocket timeout')));
    req.on('response', res => { res.resume(); reject(new Error('Upgrade returned HTTP ' + res.statusCode)); });
    req.on('upgrade', (res, socket, head) => {
      try {
        assert.equal(res.statusCode, 101);
        assert.equal(res.headers['sec-websocket-protocol'], protocol);
        assert.equal(res.headers['sec-websocket-accept'], crypto.createHash('sha1')
          .update(key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest('base64'));
      } catch (error) { socket.destroy(); reject(error); return; }
      socket.on('error', reject);
      socket.setTimeout(5000, () => socket.destroy(new Error('WebSocket pong timeout')));
      let data = head;
      socket.on('data', chunk => {
        data = Buffer.concat([data, chunk]);
        if (data.length < 6) return;
        try { assert.equal(data.subarray(0, 6).toString('hex'), '8a0470696e67'); }
        catch (error) { socket.destroy(); reject(error); return; }
        socket.destroy(); resolve();
      });
      const mask = Buffer.from([1, 2, 3, 4]);
      const payload = Buffer.from('ping').map((byte, index) => byte ^ mask[index]);
      socket.write(Buffer.concat([Buffer.from([0x89, 0x84]), mask, payload]));
    });
    req.end();
  });
}
(async () => {
  for (const spelling of [baseSecret, 'dd' + baseSecret]) {
    const capability = crypto.createHmac('sha256', Buffer.from(spelling, 'hex'))
      .update('tdesktop-web-proxy-bridge-v1\n' + domain).digest('base64url');
    const bridge = await request('GET', '/?bridge=' + capability);
    assert.equal(bridge.status, 200);
    assert.equal(bridge.headers['cache-control'], 'no-store');
    const bootstrap = /let bootstrap="([A-Za-z0-9_-]{43})"/.exec(bridge.body.toString())?.[1];
    assert.ok(bootstrap, 'bootstrap in bridge document');
    const hello = Buffer.from('100000000000000101', 'hex');
    const created = await request('POST', '/api/v1/session', {
      Authorization: 'Bearer ' + bootstrap, 'Content-Type': 'application/octet-stream', 'Content-Length': hello.length
    }, hello);
    assert.equal(created.status, 200);
    assert.equal(created.headers['x-carrier-mode'], 'websocket');
    assert.equal(created.body.toString('hex'), '1100000000000000');
    const token = created.headers['x-session-token'];
    assert.ok(token);
    await upgrade(token);
    const closed = await request('DELETE', '/api/v1/session', { Authorization: 'Bearer ' + token });
    assert.equal(closed.status, 204);
  }
  console.log('OK: plain/dd WEB-сессии, POST HELLO/WELCOME и WebSocket ping/pong через Caddy');
})().catch(error => { console.error(error); process.exitCode = 1; });
JS
}
check_web_protocol

awk '
    /^### Статический сайт$/ { recipe=1; next }
    recipe && /^```yaml$/ { block=1; next }
    block && /^```$/ { exit }
    block { print }
    END { if (!block) exit 1 }
' "$ROOT_DIR/README.md" > "$CONFIG_DIR/site-labels.yaml"
sed -i "s|      caddy:.*|      ${LABEL_PREFIX}: \"http://\${DOMAIN}\"|; s|      caddy\.|      ${LABEL_PREFIX}.|" "$CONFIG_DIR/site-labels.yaml"
awk -v labels="$CONFIG_DIR/site-labels.yaml" '
    /^    labels:/ { skip=1; while ((getline line < labels) > 0) print line; close(labels); next }
    skip && /^    logging:/ { skip=0 }
    !skip { print }
' "$COMPOSE_FILE" > "$COMPOSE_FILE.tmp"
mv "$COMPOSE_FILE.tmp" "$COMPOSE_FILE"
main update >/dev/null
for ((attempt=0; attempt<60; attempt++)); do
    wait_response 200 /
    if grep -q '"method":"GET"' "$TEST_DIR/response"; then break; fi
    sleep 0.5
done
grep -q '"method":"GET"' "$TEST_DIR/response"

status=$(command curl --noproxy '*' -sS --max-time 15 -o "$TEST_DIR/site-response.json" -w '%{http_code}' \
    -H "Host: $DOMAIN" \
    -H 'Authorization: Basic dXNlcjpwYXNz' -H 'Cookie: site=ok' \
    "$URL/page?path=a%2Fb")
if [ "$status" != 200 ]; then
    echo "Обычный GET: ожидался HTTP 200, получен $status" >&2
    exit 1
fi
docker exec "$SITE_NAME" node -e '
const r = JSON.parse(process.argv[1]);
if (r.method !== "GET" || r.url !== "/page?path=a%2Fb" || r.host !== process.argv[2]
    || r.authorization !== "Basic dXNlcjpwYXNz" || r.cookie !== "site=ok"
    || r.bytes !== 0) throw new Error("418 изменил GET-запрос");
' "$(cat "$TEST_DIR/site-response.json")" "$DOMAIN"
echo "OK: 418 сохраняет URI, Host, Cookie и Authorization сайта"
status=$(command curl --noproxy '*' -sS --max-time 10 -I -o /dev/null -w '%{http_code}' -H "Host: $DOMAIN" "$URL/page")
[ "$status" = 200 ]

before=$(docker logs "$SITE_NAME" 2>&1 | grep -c '^SITE_REQUEST$' || true)
status=$(command curl --noproxy '*' -sS --max-time 10 -o /dev/null -w '%{http_code}' \
    -H "Host: $DOMAIN" --data-binary small "$URL/upload")
[ "$status" = 405 ]
after=$(docker logs "$SITE_NAME" 2>&1 | grep -c '^SITE_REQUEST$' || true)
[ "$before" = "$after" ]
echo "OK: неподдерживаемый POST не передаётся на статический сайт"
status=$(command curl --noproxy '*' -sS --max-time 10 -o /dev/null -w '%{http_code}' \
    -H "Host: $DOMAIN" -X GET --data-binary small "$URL/upload")
[ "$status" = 405 ]
after=$(docker logs "$SITE_NAME" 2>&1 | grep -c '^SITE_REQUEST$' || true)
[ "$before" = "$after" ]
echo "OK: GET с телом не передаётся на статический сайт"

before=$(docker logs "$SITE_NAME" 2>&1 | grep -c '^SITE_REQUEST$' || true)
status=$(command curl --noproxy '*' -sS --max-time 10 -o "$TEST_DIR/invalid-response" -w '%{http_code}' \
    -H "Host: $DOMAIN" -H 'Authorization: Bearer invalid' -H 'Cookie: secret=invalid' \
    --data-binary invalid "$URL/api/v1/session?secret=invalid")
if [ "$status" != 404 ]; then
    echo "Неверные данные доступа: ожидался HTTP 404, получен $status" >&2
    exit 1
fi
[ "$(cat "$TEST_DIR/invalid-response")" = 'Not Found' ]
after=$(docker logs "$SITE_NAME" 2>&1 | grep -c '^SITE_REQUEST$' || true)
[ "$before" = "$after" ]
echo "OK: 419 даёт статический ответ без передачи данных доступа сайту"

before=$(docker logs "$SITE_NAME" 2>&1 | grep -c '^SITE_REQUEST$' || true)
check_web_protocol
after=$(docker logs "$SITE_NAME" 2>&1 | grep -c '^SITE_REQUEST$' || true)
[ "$before" = "$after" ]
echo "OK: авторизованные WEB-запросы не передаются сайту"
