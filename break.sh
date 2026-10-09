#!/usr/bin/env bash
# Break the healthy site one realistic way (staged for the demo; run ./restore.sh to undo).
#   ./break.sh white-screen | maintenance-stuck | hacked
set -euo pipefail
cd "$(dirname "$0")"
in_cli() { docker compose -p va-p5 exec -T cli "$@"; }
wp() { ./wp "$@"; }

case ${1:-} in
  white-screen)
    # A plugin "update" the way most updaters do it: keep a copy of the old version, then write the new one.
    # 1.5.0 calls a function it never shipped, on `init` — so every page, wp-admin included, dies with a fatal error.
    in_cli sh -c 'mkdir -p wp-content/upgrade-backups && rm -rf wp-content/upgrade-backups/bayview-booking-1.4.2 \
      && cp -a wp-content/plugins/bayview-booking wp-content/upgrade-backups/bayview-booking-1.4.2 \
      && cp /php/bayview-booking-1.5.0.php wp-content/plugins/bayview-booking/bayview-booking.php'
    echo "[break] white-screen: bayview-booking 1.4.2 → 1.5.0 (backup kept in wp-content/upgrade-backups/)";;

  maintenance-stuck)
    # An update of Contact Form 7 dies half-way: WordPress's own .maintenance file stays in the web root, and the
    # plugin folder is left half-copied: the copy stopped part-way through two files, which now end mid-statement.
    in_cli sh -c 'echo "<?php \$upgrading = $(date +%s); ?>" > .maintenance && cd wp-content/plugins/contact-form-7/includes \
      && for f in mail.php submission.php; do head -c $(( $(wc -c < $f) / 2 )) $f > $f.part && mv $f.part $f; done'
    echo "[break] maintenance-stuck: .maintenance left behind, contact-form-7 half-updated";;

  hacked)
    # SIMULATION. A compromise as it is usually found: an admin nobody created, SEO spam links, a "backdoor" in uploads.
    # The planted PHP file is inert: it reads no request input and only prints a fixed string.
    wp user create wp_support_admin wp.support@example.net --role=administrator \
      --user_pass="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)" --display_name="WP Support" --porcelain >/dev/null
    wp eval '
      $spam = "<div style=\"position:absolute;left:-9999px\"><a href=\"https://example.net/casino-bonus\">casino bonus</a> <a href=\"https://example.net/cheap-meds\">cheap meds</a></div>";
      foreach (get_posts(["post_type" => "post", "numberposts" => -1]) as $p)
        wp_update_post(["ID" => $p->ID, "post_content" => $p->post_content . $spam]);
      $o = get_option("astra-settings");
      $o["footer-copyright-editor"] .= " · <a href=\"https://example.com/payday-loans\">Payday loans</a> · <a href=\"https://example.com/replica-watches\">Replica watches</a>";
      update_option("astra-settings", $o);'
    in_cli sh -c 'mkdir -p wp-content/uploads/2026/10 && cat > wp-content/uploads/2026/10/wp-cache-helper.php' <<'PHP'
<?php /* SIMULATION — inert demo file for a portfolio rescue exercise. It reads no input; the payload below only prints a fixed string. */
eval(base64_decode('ZWNobyAiU0lNVUxBVElPTjogaW5lcnQgZGVtbyBmaWxlIjs='));
PHP
    echo "[break] hacked: rogue admin, spam links in posts + footer option, inert backdoor in uploads/2026/10/";;

  *) echo "usage: ./break.sh white-screen | maintenance-stuck | hacked" >&2; exit 2;;
esac
