#!/usr/bin/env bash
# Rebuild assets/photos/*.jpg (gitignored) from Wikimedia Commons — sources + licences in photos.tsv / CREDITS.md.
# Each photo becomes a 1600 px-wide JPEG at quality 80: a sensible web size, so the healthy site is fast.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p photos originals
tail -n +2 photos.tsv | while IFS=$'\t' read -r name url _; do
  out="photos/$name.jpg"; [[ -s "$out" ]] && continue
  orig=$(ls originals/"$name".* 2>/dev/null | head -1 || true)
  if [[ -z $orig ]]; then orig="originals/$name.${url##*.}"; curl -fsSL --retry 6 --retry-delay 20 -A "va-p5-seed/1.0" -o "$orig" "$url"; fi
  magick "$orig" -auto-orient -resize '1600x>' -strip -quality 80 "$out"
  echo "$out $(magick identify -format '%wx%h' "$out") $(( $(stat -f%z "$out" 2>/dev/null || stat -c%s "$out") / 1024 )) KB"
done
