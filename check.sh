#!/usr/bin/env bash
# End-to-end proof, for each incident: healthy snapshot → break.sh → assert it is broken → rescue.sh → assert it is healthy.
# Ends on the healthy snapshot. Needs: Docker, Node 22, ImageMagick 7, Playwright (PLAYWRIGHT_PATH or `npm i playwright`).
set -euo pipefail
cd "$(dirname "$0")"
URL=http://localhost:8092
t0=$(date +%s)
fail() { echo "[check] FAIL ($inc): $*" >&2; exit 1; }
ok() { echo "[check] ok   ($inc): $*"; }
code() { curl -s -o /dev/null -w '%{http_code}' "$1"; }
spam_hrefs() { curl -s "$1" | grep -Eo 'href="https?://(www\.)?example\.(com|net)[^"]*"' || true; }
wpc() { ./wp "$@" 2>/dev/null; }

inc=baseline
./restore.sh
node shots.mjs shoot baseline

for inc in white-screen maintenance-stuck hacked; do
  echo; echo "[check] ===== $inc ====="
  ./restore.sh
  ./break.sh "$inc"

  # 1. It is really broken.
  case $inc in
    white-screen)
      [[ $(code "$URL/") == 500 ]] || fail "home is not HTTP 500 after break"
      curl -s "$URL/" | grep -q 'critical error' || fail "no critical-error page"
      ok "broken: home 500, critical error page";;
    maintenance-stuck)
      [[ $(code "$URL/") == 503 ]] || fail "home is not HTTP 503 after break"
      curl -s "$URL/" | grep -q 'Briefly unavailable for scheduled maintenance' || fail "no maintenance message"
      ok "broken: home 503, maintenance message";;
    hacked)
      [[ -n $(spam_hrefs "$URL/") ]] || fail "no spam links on home after break"
      [[ $(wpc user list --role=administrator --field=user_login | wc -l) -gt 1 ]] || fail "no extra administrator after break"
      [[ -n $(wpc eval 'echo implode("\n", glob(wp_upload_dir()["basedir"]."/*/*/*.php"));') ]] || fail "no PHP file in uploads after break"
      ok "broken: spam links on home, extra admin, PHP in uploads";;
  esac
  node shots.mjs shoot "$inc-broken"

  if [[ $inc == hacked ]]; then   # a live login session and the current secrets, so we can prove the rescue replaced them
    wpc eval 'WP_Session_Tokens::get_instance(1)->create(time() + 3600);' >/dev/null
    key_before=$(wpc config get AUTH_KEY); pass_before=$(wpc user get admin --field=user_pass)
    [[ $(wpc eval 'echo count(WP_Session_Tokens::get_instance(1)->get_all());') -ge 1 ]] || fail "could not create a test session"
  fi

  # 2. The playbook.
  ./rescue.sh "$inc"

  # 3. It is healthy again: 200, every section, the booking form, and it looks like the baseline.
  [[ $(code "$URL/") == 200 ]] || fail "home is not 200 after rescue"
  html=$(curl -s "$URL/")
  for t in 'Gentle dental care' 'Our services' 'A calm clinic' 'Meet the team' 'What patients say' 'Inside the clinic' \
           'Book a visit' 'class="bd-booking"' 'class="wpcf7-form'; do
    grep -qF "$t" <<<"$html" || fail "home is missing: $t"
  done
  ok "home 200, all sections + booking form present"
  node shots.mjs shoot "$inc-healthy"
  node shots.mjs diff baseline "$inc-healthy" || fail "healthy shot differs from baseline"

  # 4. Incident-specific checks, against the live site rather than the rescue log.
  case $inc in
    white-screen)
      [[ $(wpc plugin get bayview-booking --field=status) == active ]] || fail "bayview-booking not active"
      [[ $(wpc plugin get bayview-booking --field=version) == 1.4.2 ]] || fail "bayview-booking not rolled back to 1.4.2"
      ok "bayview-booking 1.4.2 active";;
    maintenance-stuck)
      [[ $(wpc eval 'echo (int) file_exists(ABSPATH.".maintenance");') == 0 ]] || fail ".maintenance still there"
      wpc plugin verify-checksums --all >/dev/null || fail "plugin checksums fail"
      ok "no .maintenance, plugin checksums pass";;
    hacked)
      # ponytail: word-splits post URLs; WordPress permalinks have no spaces
      [[ $(wpc user list --role=administrator --field=user_login) == "$(cat admins.allow)" ]] || fail "administrators != admins.allow"
      for u in "$URL/" $(wpc post list --post_type=post,page --post_status=publish --field=url); do
        [[ -z $(spam_hrefs "$u") ]] || fail "spam link still on $u"
      done
      [[ -z $(wpc eval 'echo implode("\n", glob(wp_upload_dir()["basedir"]."/*/*/*.php"));') ]] || fail "PHP still in uploads"
      wpc core verify-checksums >/dev/null || fail "core checksums fail"
      wpc plugin verify-checksums --all >/dev/null || fail "plugin checksums fail"
      [[ $(wpc eval 'echo (int) str_contains((string) @file_get_contents(wp_upload_dir()["basedir"]."/.htaccess"), "Require all denied");') == 1 ]] \
        || fail "uploads/.htaccess does not deny PHP"
      [[ $(wpc config get AUTH_KEY) != "$key_before" ]] || fail "salts were not shuffled"
      [[ $(wpc user get admin --field=user_pass) != "$pass_before" ]] || fail "admin password was not reset"
      [[ $(wpc eval 'echo count(WP_Session_Tokens::get_instance(1)->get_all());') == 0 ]] || fail "admin sessions survived"
      ok "admins = allowlist, no spam on any page, no PHP in uploads, checksums pass, uploads PHP denied"
      ok "salts shuffled (AUTH_KEY changed), admin password hash changed, admin sessions destroyed";;
  esac
  node -e '
    const l = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    const bad = ["incident","symptom","root_cause","steps","fixed_in_s","verified"].filter((k) => l[k] == null || l[k] === "");
    if (bad.length || l.incident !== process.argv[2] || !l.steps.length || !l.verified.length) { console.error("bad log", bad); process.exit(1); }
    console.log(`[check] ok   (${l.incident}): log — ${l.steps.length} steps, fixed in ${l.fixed_in_s} s, root cause: ${l.root_cause}`);
  ' "logs/$inc.json" "$inc" || fail "logs/$inc.json incomplete"
done

inc=final
./restore.sh
echo; echo "[check] PASS — 3 incidents broken and rescued in $(( $(date +%s) - t0 ))s; site left healthy"
