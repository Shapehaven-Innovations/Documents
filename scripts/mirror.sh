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
#     tripped it returns 403 to every client for hours, then clears. One fetch
#     per day from one runner stays well clear of that; every customer install
#     fetching 11 MB on its own schedule would not.
#
# Three rules keep the mirror honest:
#   1. Never write from a response that is not the real document. A 403 error
#      page is still a "successful" download to curl. Every fetch is validated
#      before anything is written.
#   2. Commit on substance, not on bytes. The decision to write is made on the
#      hash of NORMALIZED text (see scripts/normalize.mjs). Raw-byte comparison
#      would commit nearly every day on page chrome alone, and each of those
#      commits would reach CondoGuard as a false rule-change alert.
#   3. The manifest carries no volatile fields. A fetchedAt timestamp would
#      change the hash every run and defeat rule 2 by itself.
#
set -euo pipefail

LANDING="https://www.hud.gov/hud-partners/single-family-handbook-4000-1"
CONDO_PAGE="https://www.hud.gov/hud-partners/single-family-ins-condominiums"
UA="CondoGuard-RuleMirror/1.0 (+https://github.com/${GITHUB_REPOSITORY:-local}; compliance rule monitoring)"

changed_any=0

fetch() { # url outfile -> prints http status
  # --http1.1: the handbook is ~11 MB and hud.gov's HTTP/2 stream aborts partway
  # often enough to fail a run ("curl: (92) stream 1 was not closed cleanly:
  # INTERNAL_ERROR"). HTTP/1.1 has been stable for the large transfer.
  curl -sS -L --http1.1 \
    --retry 3 --retry-delay 5 --retry-all-errors \
    --connect-timeout 30 --max-time 300 \
    -A "$UA" -o "$2" -w '%{http_code}' "$1"
}

manifest_hash() { # manifestPath -> prints stored sha256, or empty when absent
  node -e '
    const fs = require("fs");
    try { process.stdout.write(JSON.parse(fs.readFileSync(process.argv[1], "utf8")).sha256 ?? ""); }
    catch { process.stdout.write(""); }
  ' "$1"
}

write_manifest() { # sourceCode sourceUrl filename sha bytes outdir
  cat >"$6/manifest.json" <<JSON
{
  "sourceCode": "$1",
  "sourceUrl": "$2",
  "filename": "$3",
  "sha256": "$4",
  "bytes": $5
}
JSON
}

# --- HUD SFH Handbook 4000.1 (PDF, versioned filename) ----------------------
# The filename rotates with each update (Update-18-Redline today, 19 tomorrow),
# so it is resolved from the landing page every run rather than hardcoded.
echo "==> HUD Handbook 4000.1"
outdir="mirrors/hud-4000-1"
mkdir -p "$outdir"

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

# Diffing two 11 MB binaries is useless to a human reviewer, so the committed
# artifact that actually gets diffed is the extracted text. The PDF is kept so
# the reviewer can open the real document.
pdftotext -q /tmp/handbook.pdf /tmp/handbook.raw.txt
[ -s /tmp/handbook.raw.txt ] || { echo "FATAL: pdftotext produced no text"; exit 1; }

sha="$(node scripts/normalize.mjs /tmp/handbook.raw.txt text /tmp/handbook.norm.txt)"
bytes="$(wc -c </tmp/handbook.pdf | tr -d ' ')"
if [ "$sha" = "$(manifest_hash "$outdir/manifest.json")" ]; then
  echo "  unchanged (sha256=${sha:0:16}…) — nothing written"
else
  cp /tmp/handbook.pdf "$outdir/handbook.pdf"
  cp /tmp/handbook.norm.txt "$outdir/handbook.txt"
  write_manifest "HUD_4000_1_HANDBOOK_PDF" "$pdf_url" "$filename" "$sha" "$bytes" "$outdir"
  echo "  CHANGED  sha256=${sha:0:16}… bytes=$bytes"
  changed_any=1
fi

# --- HUD FHA Condominiums page (HTML) ---------------------------------------
echo "==> HUD FHA Condominiums page"
outdir="mirrors/hud-condo"
mkdir -p "$outdir"

status="$(fetch "$CONDO_PAGE" /tmp/condo.html)"
[ "$status" = "200" ] || { echo "FATAL: condo page http=$status"; exit 1; }
# Sanity floor: the real page is tens of KB; a block page is a few hundred bytes.
[ "$(wc -c </tmp/condo.html)" -gt 10000 ] || { echo "FATAL: condo page too small to be real"; exit 1; }

sha="$(node scripts/normalize.mjs /tmp/condo.html html /tmp/condo.norm.txt)"
bytes="$(wc -c </tmp/condo.html | tr -d ' ')"
if [ "$sha" = "$(manifest_hash "$outdir/manifest.json")" ]; then
  echo "  unchanged (sha256=${sha:0:16}…) — nothing written"
else
  cp /tmp/condo.html "$outdir/page.html"
  cp /tmp/condo.norm.txt "$outdir/page.txt"
  write_manifest "HUD_CONDO_PAGE" "$CONDO_PAGE" "page.html" "$sha" "$bytes" "$outdir"
  echo "  CHANGED  sha256=${sha:0:16}… bytes=$bytes"
  changed_any=1
fi

if [ "$changed_any" = "0" ]; then
  echo "==> Mirror complete — no substantive changes"
else
  echo "==> Mirror complete — changes written"
fi
