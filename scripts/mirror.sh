#!/usr/bin/env bash
#
# Mirrors HUD publications so consumers watch a stable, cheap manifest.
#
# Why mirror at all:
#   - HUD's handbook filename is versioned (…-Update-18-Redline.pdf → -19-), so
#     a fixed URL freezes and reports "no changes" forever. Resolved per run.
#   - hud.gov sends no ETag/Last-Modified, so every direct check downloads the
#     full 11.4 MB. The manifest is ~300 bytes and raw.githubusercontent.com
#     supports conditional requests.
#   - hud.gov applies Cloudflare rate-based mitigation per egress IP: once
#     tripped it returns 403 to every client for hours, then clears. One
#     fetch per month from one runner stays well clear of that.
#
# Two rules keep the mirror honest:
#   1. Never write a manifest from a response that is not the real document.
#      A 403 error page is still a 200-byte "successful" download to curl -O;
#      writing it would silently replace the real hash and fire a bogus change
#      alert. Every fetch is validated before anything is committed.
#   2. The manifest holds no volatile fields. A fetchedAt timestamp would change
#      the hash on every run and make the watcher cry wolf once a month forever.
#
set -euo pipefail

LANDING="https://www.hud.gov/hud-partners/single-family-handbook-4000-1"
CONDO_PAGE="https://www.hud.gov/hud-partners/single-family-ins-condominiums"
UA="CondoGuard-RuleMirror/1.0 (+https://github.com/${GITHUB_REPOSITORY:-local}; compliance rule monitoring)"

fetch() { # url outfile -> prints http status
  # --http1.1: the handbook is ~11 MB and hud.gov's HTTP/2 stream aborts partway
  # often enough to fail a run ("curl: (92) stream 1 was not closed cleanly:
  # INTERNAL_ERROR"). HTTP/1.1 has been stable for the large transfer.
  # --retry covers the transient case without hiding a real block: a 403 is not
  # retried by --retry-all-errors' backoff into a false success, because the
  # status is still checked by the caller.
  curl -sS -L --http1.1 \
    --retry 3 --retry-delay 5 --retry-all-errors \
    --connect-timeout 30 --max-time 300 \
    -A "$UA" -o "$2" -w '%{http_code}' "$1"
}

write_manifest() { # sourceCode sourceUrl filename file outdir
  local code="$1" url="$2" filename="$3" file="$4" outdir="$5"
  local sha bytes
  sha="$(shasum -a 256 "$file" | awk '{print $1}')"
  bytes="$(wc -c <"$file" | tr -d ' ')"
  # Stable fields only — see rule 2 above.
  cat >"$outdir/manifest.json" <<JSON
{
  "sourceCode": "$code",
  "sourceUrl": "$url",
  "filename": "$filename",
  "sha256": "$sha",
  "bytes": $bytes
}
JSON
  echo "  manifest: sha256=${sha:0:16}… bytes=$bytes"
}

# --- HUD SFH Handbook 4000.1 (PDF, versioned filename) ----------------------
# The filename rotates with each update (Update-18-Redline today, 19 tomorrow),
# so it is resolved from the landing page every run rather than hardcoded.
echo "==> HUD Handbook 4000.1"
mkdir -p mirrors/hud-4000-1
status="$(fetch "$LANDING" /tmp/landing.html)"
[ "$status" = "200" ] || { echo "FATAL: landing page http=$status"; exit 1; }

href="$(grep -oE 'href="[^"]*4000[^"]*\.pdf"' /tmp/landing.html \
        | sed -E 's/^href="//; s/"$//' | sort -u | head -1)"
[ -n "$href" ] || { echo "FATAL: no 4000.1 PDF link found — HUD changed the page layout"; exit 1; }
case "$href" in
  http*) pdf_url="$href" ;;
  /*)    pdf_url="https://www.hud.gov$href" ;;
  *)     pdf_url="https://www.hud.gov/$href" ;;
esac
filename="$(basename "$pdf_url")"
echo "  resolved: $filename"

status="$(fetch "$pdf_url" /tmp/handbook.pdf)"
[ "$status" = "200" ] || { echo "FATAL: PDF http=$status"; exit 1; }
# Rule 1: a 403 error page is HTML, not a PDF. Refuse to mirror it.
head -c 5 /tmp/handbook.pdf | grep -q '%PDF' || {
  echo "FATAL: response is not a PDF (got: $(head -c 40 /tmp/handbook.pdf))"; exit 1; }

cp /tmp/handbook.pdf mirrors/hud-4000-1/handbook.pdf
write_manifest "HUD_4000_1_HANDBOOK_PDF" "$pdf_url" "$filename" /tmp/handbook.pdf mirrors/hud-4000-1

# --- HUD FHA Condominiums page (HTML) ---------------------------------------
echo "==> HUD FHA Condominiums page"
mkdir -p mirrors/hud-condo
status="$(fetch "$CONDO_PAGE" /tmp/condo.html)"
[ "$status" = "200" ] || { echo "FATAL: condo page http=$status"; exit 1; }
# Sanity floor: the real page is tens of KB; a block page is a few hundred bytes.
[ "$(wc -c </tmp/condo.html)" -gt 10000 ] || { echo "FATAL: condo page too small to be real"; exit 1; }

cp /tmp/condo.html mirrors/hud-condo/page.html
write_manifest "HUD_CONDO_PAGE" "$CONDO_PAGE" "page.html" /tmp/condo.html mirrors/hud-condo

echo "==> Mirror complete"
