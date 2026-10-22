#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
unset VK_TOKEN VK_GROUP_ID VK_ADMIN_IDS COMPOSE_PROJECT_NAME
mkdir -p "$TEST_DIR/first/bot" "$TEST_DIR/second/bot"
for directory in "$TEST_DIR/first/bot" "$TEST_DIR/second/bot"; do
    cp "$ROOT_DIR/bot/compose.yaml" "$ROOT_DIR/bot/compose.required.yaml" "$directory/"
done

# Real Compose interpolation, not the Docker stub from lifecycle tests.
# No Docker daemon or real VK credentials are needed.
cd "$TEST_DIR/first/bot"
docker compose config --quiet
if docker compose -f compose.yaml -f compose.required.yaml config --quiet >/dev/null 2>&1; then
    echo 'Startup accepted missing credentials' >&2; exit 1
fi
printf 'VK_TOKEN=test\nVK_GROUP_ID=1\nVK_ADMIN_IDS=2\n' > .env
docker compose -f compose.yaml -f compose.required.yaml config --quiet
for name in first second; do
    directory="$TEST_DIR/$name"
    project="mtproxy-manager-bot-$(printf '%s' "$directory" | sha256sum | cut -c1-12)"
    (cd "$directory/bot"; docker compose -p "$project" config --format json) > "$TEST_DIR/$name.json"
done
python3 - "$TEST_DIR" <<'PY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
a, b = [json.loads((root / f'{name}.json').read_text()) for name in ('first', 'second')]
assert a['name'] != b['name']
assert a['volumes']['bot-data']['name'] != b['volumes']['bot-data']['name']
assert a['services']['bot']['image'] != b['services']['bot']['image']
assert a['services']['bot']['healthcheck']['test']
PY
rm .env
docker compose config --quiet
echo 'Bot Compose tests passed.'
