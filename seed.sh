#!/usr/bin/env bash
# Build the healthy Bayview Dental site from nothing, then snapshot it for restore.sh.
#   ./seed.sh            (needs assets/photos — assets/fetch-photos.sh builds them)
set -euo pipefail
cd "$(dirname "$0")"
URL=http://localhost:8092
# Pinned so checksums and the maintenance-stuck reinstall always mean the same files.
ASTRA=4.14.0 ELEMENTOR=4.3.4 CF7=6.2.1
wp() { ./wp "$@"; }
in_cli() { docker compose -p va-p5 exec -T cli "$@"; }

[[ $(ls assets/photos/*.jpg 2>/dev/null | wc -l) -ge 10 ]] || assets/fetch-photos.sh
mkdir -p snapshot quarantine
docker compose -p va-p5 up -d
printf 'waiting for wordpress'; until curl -fsS -o /dev/null "$URL/wp-includes/images/blank.gif" 2>/dev/null; do printf .; sleep 2; done; echo

wp core is-installed 2>/dev/null || wp core install --url=$URL --title="Bayview Dental" \
  --admin_user=admin --admin_password=admin --admin_email=admin@example.com --skip-email
wp plugin delete akismet hello 2>/dev/null || true
wp theme install astra --version=$ASTRA --activate
wp theme delete twentytwentythree twentytwentyfour twentytwentyfive 2>/dev/null || true
wp plugin install elementor --version=$ELEMENTOR --activate
wp plugin install contact-form-7 --version=$CF7 --activate
in_cli sh -c 'rm -rf wp-content/plugins/bayview-booking && cp -r /php/bayview-booking wp-content/plugins/'
wp plugin activate bayview-booking

if [[ -z $(wp post list --post_type=attachment --name=hero-1 --format=ids) ]]; then
  in_cli sh -c 'wp media import /photos/*.jpg --porcelain' >/dev/null
fi
wp option update elementor_local_google_fonts 1   # fonts from the site itself: no third-party request, same look offline
wp eval-file /php/site.php
wp eval-file /php/build-home.php
wp rewrite flush
in_cli sh -c 'cat > .htaccess' <<'HT'   # WP-CLI can't see mod_rewrite from its container, so write WordPress's standard block
# BEGIN WordPress
<IfModule mod_rewrite.c>
RewriteEngine On
RewriteRule .* - [E=HTTP_AUTHORIZATION:%{HTTP:Authorization}]
RewriteBase /
RewriteRule ^index\.php$ - [L]
RewriteCond %{REQUEST_FILENAME} !-f
RewriteCond %{REQUEST_FILENAME} !-d
RewriteRule . /index.php [L]
</IfModule>
# END WordPress
HT
for _ in 1 2; do curl -fsS -o /dev/null "$URL/"; done   # first views write Elementor's CSS and local fonts, so the snapshot holds them
./snapshot.sh
echo "seeded: $URL  (admin/admin)"
