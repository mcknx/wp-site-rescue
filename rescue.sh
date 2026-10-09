#!/usr/bin/env bash
# The rescue playbook for one incident: diagnose from evidence → fix → verify. Prints a timed step log and writes
# logs/<incident>.json. Nothing below knows what break.sh did: plugin names, files, users and spam come from
# HTTP responses, debug.log, WP-CLI and the database at run time.
#   ./rescue.sh white-screen | maintenance-stuck | hacked
set -euo pipefail
cd "$(dirname "$0")"
URL=http://localhost:8092
INC=${1:-}
ALLOWED_LINK_HOSTS="gmpg.org"     # external links the healthy theme itself prints (WordPress's XFN profile link)
SECTIONS=('Our services' 'Meet the team' 'Book a visit' 'class="bd-booking"' 'class="wpcf7-form')

now() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }
T0=$(now)
mkdir -p logs
STEPS=$(mktemp); VERIFIED=$(mktemp); trap 'rm -f "$STEPS" "$VERIFIED"' EXIT
step() {   # step <name> <evidence>
  local t ev; t=$(perl -e "printf '%.1f', $(now) - $T0"); ev=$(printf '%s' "$2" | tr '\t\n' '  ' | sed 's/  */ /g')
  echo "[t+${t}s] $1: $ev"; printf '%s\t%s\t%s\n' "$t" "$1" "$ev" >>"$STEPS"
}
verified() { echo "          ✓ $1"; echo "$1" >>"$VERIFIED"; }
die() { step "FAILED" "$1"; exit 1; }
wp() { ./wp "$@" 2>/dev/null; }                   # WP-CLI output only; its warnings are not evidence
in_cli() { docker compose -p va-p5 exec -T cli "$@"; }
code() { curl -s -o /dev/null -w '%{http_code}' "$URL${1:-/}"; }
last_fatal() { in_cli sh -c 'grep -E "PHP (Fatal|Parse) error" wp-content/debug.log 2>/dev/null | tail -1' | sed -E 's/^\[[^]]*\] //'; }
fatal_count() { in_cli sh -c 'grep -cE "PHP (Fatal|Parse) error" wp-content/debug.log 2>/dev/null || true'; }
plugin_of() { { grep -Eo 'wp-content/plugins/[^/]+' <<<"$1" || true; } | head -1 | cut -d/ -f3; }
# The whole last fatal entry, stack trace included (debug.log writes the trace on the lines after the error line).
last_fatal_trace() { in_cli sh -c 'awk "/PHP (Fatal|Parse) error/ {b=\"\"} {b=b \$0 \"\n\"} END {printf \"%s\", b}" wp-content/debug.log 2>/dev/null'; }

verify_home() {   # the checks every rescue ends with
  local c html; c=$(code /); [[ $c == 200 ]] || die "home still HTTP $c"
  html=$(curl -s "$URL/")
  for s in "${SECTIONS[@]}"; do grep -qF "$s" <<<"$html" || die "home is missing $s"; done
  verified "home HTTP 200 with every section and the booking form"
  c=$(code /wp-login.php); [[ $c == 200 ]] || die "wp-login.php HTTP $c"; verified "wp-login.php HTTP 200"
}

write_log() {   # write_log <symptom> <root cause>
  local fixed; fixed=$(perl -e "printf '%.1f', $(now) - $T0")
  node -e '
    const fs = require("fs"), [steps, ver, incident, symptom, root_cause, fixed] = process.argv.slice(1);
    const log = { incident, symptom, root_cause,
      steps: fs.readFileSync(steps, "utf8").trim().split("\n").map((l) => { const [t, step, evidence] = l.split("\t"); return { t: +t, step, evidence }; }),
      fixed_in_s: +fixed, verified: fs.readFileSync(ver, "utf8").trim().split("\n"), finished_at: new Date().toISOString() };
    fs.writeFileSync(`logs/${incident}.json`, JSON.stringify(log, null, 2) + "\n");
  ' "$STEPS" "$VERIFIED" "$INC" "$1" "$2" "$fixed"
  echo "[rescue] $INC fixed in $fixed s → logs/$INC.json"
}

case $INC in
# ---------------------------------------------------------------------------------------------------------------------
white-screen)
  c=$(code /); msg=$(curl -s "$URL/" | grep -o 'There has been a critical error[^.<]*' | head -1 || true)
  [[ $c == 500 ]] || die "home is HTTP $c, not the 500 this playbook handles"
  symptom="Home page returns HTTP $c: \"$msg.\""
  step "probe" "GET / → HTTP $c, \"$msg\"; wp-admin too: /wp-login.php → HTTP $(code /wp-login.php)"

  fatal=$(last_fatal); [[ -n $fatal ]] || die "no fatal error in wp-content/debug.log"
  slug=$(plugin_of "$fatal" || true); [[ -n $slug ]] || die "fatal error is not in a plugin: $fatal"
  step "read debug.log" "$(sed 's/ Stack trace:.*//' <<<"$fatal")"
  bad=$(wp plugin get "$slug" --field=version --skip-plugins)
  func=$(grep -Eo 'undefined function [a-z0-9_]+\(\)' <<<"$fatal" || true)
  where=$({ grep -Eo '[a-z0-9_-]+\.php:[0-9]+' <<<"$fatal" || true; } | head -1)
  hook=$({ grep -Eo "do_action\('[a-z0-9_]+'\)" <<<"$(last_fatal_trace)" || true; } | tail -1 | grep -Eo "'[a-z0-9_]+'" | tr -d "'" || true)
  root_cause="$slug $bad: ${func:+Call to $func }at ${where:-an unknown line}${hook:+, run from the WordPress '$hook' hook (do_action('$hook') in the stack trace)} — a fatal error that took the home page and wp-login.php to HTTP 500."
  step "identify" "plugin $slug, version $bad (from the stack trace path)"

  wp plugin deactivate "$slug" --skip-plugins >/dev/null
  c=$(code /); box=$(curl -s "$URL/" | grep -q 'class="bd-booking"' && echo "booking box shown" || echo "site up, but no booking box")
  step "deactivate" "wp plugin deactivate $slug --skip-plugins → home HTTP $c ($box)"

  backup=$(in_cli sh -c "ls -d wp-content/upgrade-backups/$slug-* 2>/dev/null | sort -V | tail -1")
  [[ -n $backup ]] || die "no previous version of $slug in wp-content/upgrade-backups/"
  good=$(in_cli sh -c "grep -m1 -Eo 'Version: *[0-9.]+' $backup/$slug.php" | grep -Eo '[0-9.]+$')
  in_cli sh -c "rm -rf wp-content/plugins/$slug && cp -a $backup wp-content/plugins/$slug"
  step "roll back" "$slug $bad → $good, copied from $backup"

  before=$(fatal_count)
  wp plugin activate "$slug" >/dev/null
  step "re-activate" "wp plugin activate $slug → $(wp plugin get "$slug" --field=status) $(wp plugin get "$slug" --field=version)"

  verify_home
  [[ $(fatal_count) == "$before" ]] || die "new fatal errors after re-activation"; verified "no new fatal errors in debug.log"
  [[ $(wp plugin get "$slug" --field=version) == "$good" ]] || die "$slug is not $good"; verified "$slug $good active"
  write_log "$symptom" "$root_cause";;

# ---------------------------------------------------------------------------------------------------------------------
maintenance-stuck)
  c=$(code /); msg=$(curl -s "$URL/" | grep -o 'Briefly unavailable[^<]*' | head -1 || true)
  [[ $c == 503 && -n $msg ]] || die "home is HTTP $c without the maintenance message"
  symptom="Every page returns HTTP $c: \"$msg\""
  step "probe" "GET / → HTTP $c, \"$msg\""

  stamp=$(in_cli sh -c 'cat .maintenance 2>/dev/null' | grep -Eo '[0-9]{9,}' || true)
  [[ -n $stamp ]] || die "no .maintenance file in the web root"
  step "find .maintenance" "web root has .maintenance from an update started $(( $(date +%s) - stamp )) s ago (\$upgrading = $stamp); WordPress writes it before an update and deletes it after"
  in_cli rm -f .maintenance
  c=$(code /)
  step "remove .maintenance" "rm .maintenance → home HTTP $c$([[ $c != 200 ]] && echo ' — the update it belonged to never finished')"

  fatal=""
  if [[ $c != 200 ]]; then
    fatal=$(last_fatal); step "read debug.log" "$(sed 's/ Stack trace:.*//' <<<"$fatal")"
  fi
  sums=$(./wp plugin verify-checksums --all --skip-plugins --format=json 2>/dev/null || true)
  bad=$(node -e 'console.log([...new Set(JSON.parse(process.argv[1] || "[]").map((x) => x.plugin_name))].join(" "))' "$sums")
  [[ $(wc -w <<<"$bad") -eq 1 ]] || die "expected one broken plugin, checksums say: ${sums:-nothing wrong}"
  files=$(node -e 'console.log(JSON.parse(process.argv[1]).map((x) => `${x.file} (${x.message.toLowerCase()})`).join(", "))' "$sums")
  nfiles=$(node -e 'console.log(JSON.parse(process.argv[1]).length)' "$sums")
  ver=$(wp plugin get "$bad" --field=version --skip-plugins)
  step "verify checksums" "wp plugin verify-checksums --all → $bad $ver: $files; every other wordpress.org plugin matches"
  after=$([[ -n $fatal ]] && echo "; with .maintenance removed, home returned HTTP $c: $(sed -E 's/ Stack trace:.*//; s#/var/www/html/##g' <<<"$fatal")" || echo "; with .maintenance removed, home returned HTTP $c")
  root_cause="An update that never finished: WordPress's .maintenance file was left in the web root (every page HTTP 503), and $bad $ver fails its wordpress.org checksums on $nfiles files ($(sed 's/ ([^)]*)//g' <<<"$files"))$after."

  ./wp plugin install "$bad" --version="$ver" --force --skip-plugins >/dev/null 2>&1
  step "reinstall" "wp plugin install $bad --version=$ver --force → $(wp plugin get "$bad" --field=status) $(wp plugin get "$bad" --field=version)"

  verify_home
  in_cli test ! -e .maintenance || die ".maintenance is back"; verified "no .maintenance in the web root"
  ./wp plugin verify-checksums --all >/dev/null 2>&1 || die "plugin checksums fail"; verified "every wordpress.org plugin matches its checksums"
  write_log "$symptom" "$root_cause";;

# ---------------------------------------------------------------------------------------------------------------------
hacked)
  # 1. Outbound links on every public page, minus the site's own host and the theme's known links.
  own=$(wp option get home | sed -E 's#https?://##; s#/.*##')
  allowed="$own $ALLOWED_LINK_HOSTS"
  report=""; spam_hosts=""
  pages=$(printf '%s\n' "$URL/" $(wp post list --post_type=post,page --post_status=publish --field=url) | sort -u)
  # ponytail: unquoted word-splitting over URLs, logins and paths here; a value with a space would split (none do on WordPress URLs/logins or these uploads), use while-read loops if that changes
  for u in $pages; do
    hosts=$(curl -s "$u" | grep -Eo 'href="https?://[^/"]+' | sed -E 's#href="https?://##; s#^www\.##' || true)
    for h in $allowed; do hosts=$(grep -vxF "$h" <<<"$hosts" || true); done
    [[ -z $hosts ]] && continue
    report+="${u#$URL} → $(sort <<<"$hosts" | uniq -c | awk '{printf "%s link%s to %s, ", $1, ($1>1?"s":""), $2}' | sed 's/, $//'); "
    spam_hosts+=" $hosts"
  done
  spam_hosts=$(tr ' ' '\n' <<<"$spam_hosts" | sed '/^$/d' | sort -u | paste -sd' ' -)
  [[ -n $spam_hosts ]] || die "no unexpected outbound links"
  symptom="Spam links on the site: ${report%; }."
  step "scan links" "${report%; }"

  # 2. Administrators nobody approved.
  admins=$(wp user list --role=administrator --fields=ID,user_login,user_email,user_registered --format=csv | tail -n +2 | tr -d '"')
  rogue=$(cut -d, -f2 <<<"$admins" | grep -vxF -f admins.allow || true)
  keep_id=$(grep -F ",$(head -1 admins.allow)," <<<"$admins" | cut -d, -f1)
  step "audit admins" "$(wc -l <<<"$admins" | tr -d ' ') administrators, allowlist has $(wc -l <admins.allow | tr -d ' '); not on it: $(for r in $rogue; do grep -F ",$r," <<<"$admins" | awk -F, '{printf "%s <%s> created %s UTC; ", $2, $3, $4}'; done | sed 's/; $//')"

  # 3. Code that should not be there.
  core=$(./wp core verify-checksums 2>&1 | tail -1)
  plug=$(./wp plugin verify-checksums --all --skip-plugins 2>&1 | tail -1)
  custom=$(in_cli sh -c 'for d in /php/*/; do s=$(basename "$d"); diff -rq "$d" "wp-content/plugins/$s" >/dev/null && echo "$s matches its repo copy" || echo "$s DIFFERS from its repo copy"; done')
  step "verify checksums" "core: $core | wordpress.org plugins: $plug | custom: $custom"
  php_files=$(in_cli find wp-content/uploads -name '*.php' | sort)
  sigs=$(in_cli sh -c "grep -rlE 'eval\(base64_decode|eval\(gzinflate|eval\(str_rot13' wp-content/uploads wp-content/themes wp-content/mu-plugins 2>/dev/null || true")
  step "scan for backdoors" "PHP files in uploads: ${php_files:-none}; malware signatures (eval(base64_decode …): ${sigs:-none}"

  rc_users=$(for r in $rogue; do printf '%s, ' "$r"; done | sed 's/, $//')
  root_cause="Site compromised: administrator ${rc_users:-none} that is not on the allowlist, a PHP backdoor in uploads ($(echo $php_files $sigs | tr ' ' '\n' | sort -u | paste -sd' ' -)), and spam links to $(sed 's/ /, /g' <<<"$spam_hosts") injected into the database."

  # 4. Contain: quarantine the files outside the web root (kept as evidence), remove the rogue users.
  qdir=/quarantine/$(date -u +%Y%m%dT%H%M%SZ)
  for f in $(echo $php_files $sigs | tr ' ' '\n' | sort -u); do
    h=$(in_cli sha256sum "$f" | cut -c1-16)
    in_cli sh -c "mkdir -p $qdir/$(dirname "$f") && mv $f $qdir/$f"
    step "quarantine" "$f (sha256 ${h}…) → .${qdir}/$f, outside the web root"
  done
  for r in $rogue; do
    n=$(wp post list --author="$(grep -F ",$r," <<<"$admins" | cut -d, -f1)" --post_type=any --format=count)
    wp user delete "$r" --reassign="$keep_id" --yes >/dev/null
    step "remove rogue admin" "wp user delete $r --reassign=$keep_id ($n posts moved to $(head -1 admins.allow))"
  done

  # 5. Clean the spam: find the exact injected markup around each spam link, remove those strings everywhere.
  hosts_re=$(sed 's/\./\\./g; s/ /|/g' <<<"$spam_hosts")
  a_re="<a [^>]*href=\"https?://(www\\.)?($hosts_re)[^\"]*\"[^>]*>[^<]*</a>"
  # ponytail: matches a hidden <div> of spam links or a bare spam link with its separator; other wrappers need a new pattern
  found=$(./wp db search "(<div[^>]*>\\s*($a_re\\s*)+</div>|(\\s*·\\s*)?$a_re)" --regex --all-tables --matches_only \
    --before_context=0 --after_context=0 --format=json 2>/dev/null)
  where=$(node -e 'const r = JSON.parse(process.argv[1]); console.log([...new Set(r.map((x) => `${x.table}.${x.column}#${x.primary_key_value}`))].join(", "))' "$found")
  blocks=$(node -e 'const r = JSON.parse(process.argv[1]); console.log([...new Set(r.flatMap((x) => x.match.split(" [...] ")))].join("\n"))' "$found")
  step "locate spam" "wp db search → $(wc -l <<<"$blocks" | tr -d ' ') distinct injected snippets in $where"
  while IFS= read -r b; do
    [[ -z $b ]] && continue
    n=$(wp search-replace "$b" '' --all-tables --precise --format=count </dev/null)   # exec -T would eat the loop's stdin
    step "remove spam" "wp search-replace '$(cut -c1-90 <<<"$b")…' '' → $n $([[ $n == 1 ]] && echo row || echo rows) changed"
  done <<<"$blocks"

  # 6. Lock the doors: new passwords for every admin, new salts (logs everyone out), no PHP execution in uploads.
  for a in $(wp user list --role=administrator --field=user_login); do
    wp user reset-password "$a" --skip-email >/dev/null
    ./wp user session destroy "$a" --all >/dev/null 2>&1
  done
  step "reset passwords" "new passwords for: $(wp user list --role=administrator --field=user_login | paste -sd, -) (not shown); all sessions destroyed"
  wp config shuffle-salts >/dev/null
  step "shuffle salts" "wp config shuffle-salts → every login cookie is now invalid"
  in_cli sh -c 'printf "%s\n" "# Never run PHP from uploads (added by the rescue)" "<FilesMatch \"\\.(php|phtml|phar)$\">" "  Require all denied" "</FilesMatch>" > wp-content/uploads/.htaccess'
  in_cli sh -c 'echo "<?php echo \"probe\";" > wp-content/uploads/rescue-probe.php'
  pc=$(code /wp-content/uploads/rescue-probe.php); in_cli rm -f wp-content/uploads/rescue-probe.php
  step "harden uploads" "wp-content/uploads/.htaccess denies PHP; a test .php there now answers HTTP $pc"

  # 7. Verify.
  verify_home
  for u in $pages; do
    curl -s "$u" | grep -Eq "href=\"https?://(www\\.)?($hosts_re)" && die "spam link still on $u"
  done
  verified "no links to $(sed 's/ /, /g' <<<"$spam_hosts") on any public page"
  [[ $(wp user list --role=administrator --field=user_login) == "$(cat admins.allow)" ]] || die "administrators != allowlist"
  verified "administrators = allowlist ($(paste -sd, - <admins.allow))"
  [[ -z $(in_cli find wp-content/uploads -name '*.php') ]] || die "PHP still in uploads"; verified "no PHP files in uploads"
  ./wp core verify-checksums >/dev/null 2>&1 || die "core checksums fail"; verified "WordPress core matches its checksums"
  ./wp plugin verify-checksums --all >/dev/null 2>&1 || die "plugin checksums fail"; verified "every wordpress.org plugin matches its checksums"
  [[ $pc == 403 ]] || die "PHP in uploads answers HTTP $pc"; verified "PHP in uploads is denied (HTTP 403)"
  write_log "$symptom" "$root_cause";;

*) echo "usage: ./rescue.sh white-screen | maintenance-stuck | hacked" >&2; exit 2;;
esac
