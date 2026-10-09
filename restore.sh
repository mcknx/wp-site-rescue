#!/usr/bin/env bash
# Put the site back to the healthy snapshot, byte for byte: database + the whole docroot
# (so plugins, .maintenance, uploads, .htaccess, wp-config salts and debug.log are exactly as seeded).
set -euo pipefail
cd "$(dirname "$0")"
[[ -s snapshot/healthy.sql && -s snapshot/healthy.tar ]] || { echo "no snapshot — run ./seed.sh first" >&2; exit 1; }
mkdir -p quarantine
docker compose -p va-p5 up -d 2>/dev/null
in_cli() { docker compose -p va-p5 exec -T cli "$@"; }
in_cli wp db reset --yes --quiet
in_cli wp db import /snap/healthy.sql --quiet
in_cli sh -c 'cd /var/www/html && find . -mindepth 1 -delete && tar -xf /snap/healthy.tar'
docker compose -p va-p5 restart wp >/dev/null 2>&1   # drop PHP's opcache of any broken files
until [[ $(curl -s -o /dev/null -w '%{http_code}' http://localhost:8092/) == 200 ]]; do sleep 1; done
echo "[restore] healthy snapshot restored"
