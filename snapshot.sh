#!/usr/bin/env bash
# Save the current site as the "healthy" snapshot: database dump + the whole docroot (snapshot/, gitignored).
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p snapshot
./wp db export /snap/healthy.sql --quiet
docker compose -p va-p5 exec -T cli sh -c 'rm -f wp-content/debug.log && tar -C /var/www/html -cf /snap/healthy.tar .'
echo "[snapshot] healthy: $(du -sh snapshot | cut -f1)"
