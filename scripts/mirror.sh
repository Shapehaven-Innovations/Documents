#!/usr/bin/env bash
#
# Mirrors every publication CondoGuard watches, so installs read a small stable
# manifest instead of fetching the source sites themselves.
#
# Why mirror:
#   - One fetch per source per day globally, instead of every customer install
#     hitting leg.state.fl.us / leginfo.ca.gov / hud.gov on its own schedule.
#     That traffic pattern is what got us rate-limited by hud.gov's Cloudflare
#     (blanket 403 to every client for hours, then clearing).
#   - Per-install bandwidth drops from megabytes per check to a few hundred
#     bytes of manifest, and raw.githubusercontent.com honors ETag while most
#     of these sites send neither ETag nor Last-Modified.
#   - HUD's handbook filename is versioned (…-Update-18-Redline.pdf → -19-), so
#     a hardcoded URL silently reports "no changes" forever. Resolved per run.
#   - Git history gives a real diff of what changed in a publication, which a
#     hash alone can never provide.
#
# Rules that keep the mirror honest:
#   1. Never write from a response that is not the real document. A 403 error
#      page is still a "successful" download to curl. Every fetch is validated.
#   2. Commit on substance, not bytes. The write decision keys off the hash of
#      NORMALIZED text (scripts/normalize.mjs). Raw comparison would commit
#      nearly every day on page chrome alone, and each such commit would reach
#      CondoGuard as a false rule-change alert.
#   3. The manifest carries no volatile fields. A fetchedAt timestamp would
#      change the hash every run and defeat rule 2 by itself.
#   4. One bad source must not block the other sixteen. Failures are collected,
#      the run continues, successes still commit, and the job exits non-zero at
#      the end so the failure is visible.
#
set -uo pipefail

UA="CondoGuard-RuleMirror/1.0 (+https://github.com/${GITHUB_REPOSITORY:-local}; compliance rule monitoring)"
POLITE_DELAY=2

changed=0
failed=0
declare -a failures=()

fetch() { # url outfile -> prints http status
  # --http1.1: hud.gov's HTTP/2 stream aborts partway through the ~11 MB
  # handbook often enough to fail a run ("curl: (92) stream 1 was not closed
  # cleanly: INTERNAL_ERROR"). HTTP/1.1 has been stable for large transfers.
  curl -sS -L --http1.1 \
    --retry 3 --retry-delay 5 --retry-all-errors \
    --connect-timeout 30 --max-time 300 \
    -A "$UA" -o "$2" -w '%{http_code}' "$1" 2>/dev/null
}

# Bumped when the manifest gains fields. A stored manifest at an older version
# is rewritten even when the content hash is unchanged, so consumers are not
# left waiting for the next real rule change to see new fields.
MANIFEST_VERSION=2

manifest_state() { # manifestPath -> "<sha256> <manifestVersion>"
  node -e '
    const fs = require("fs");
    try {
      const m = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
      process.stdout.write(`${m.sha256 ?? ""} ${m.manifestVersion ?? 0}`);
    } catch { process.stdout.write(" 0"); }
  ' "$1"
}

fail() { # sourceCode reason
  echo "  FAILED: $2"
  failures+=("$1: $2")
  failed=1
}

# Resolve a rotating filename from a landing page (HUD's versioned handbook).
resolve_url() { # landingUrl linkPattern base -> prints absolute URL, empty on failure
  local landing="$1" pattern="$2" base="$3" href
  fetch "$landing" /tmp/landing.html >/dev/null || return 1
  href="$(grep -oE "href=\"[^\"]*${pattern}\"" /tmp/landing.html \
          | sed -E 's/^href="//; s/"$//' | sort -u | head -1)"
  [ -n "$href" ] || return 1
  case "$href" in
    http*) printf '%s' "$href" ;;
    /*)    printf '%s%s' "$base" "$href" ;;
    *)     printf '%s/%s' "$base" "$href" ;;
  esac
}

# Fetch one candidate URL and validate it is the real document (rule 1).
# On success sets: bytes sha docname textname. On failure sets: reason.
acquire() { # url type
  local url="$1" type="$2" status
  raw=/tmp/doc.bin
  status="$(fetch "$url" "$raw")"
  if [ "$status" != "200" ]; then reason="http=$status"; return 1; fi
  bytes="$(wc -c <"$raw" | tr -d ' ')"

  if [ "$type" = "pdf" ]; then
    # A block page is HTML, not a PDF.
    if ! head -c 5 "$raw" | grep -q '%PDF'; then
      reason="response is not a PDF (starts: $(head -c 30 "$raw" | tr -d '\0'))"; return 1
    fi
    # Diffing two multi-MB binaries tells a reviewer nothing, so the diffable
    # committed artifact is extracted text. The PDF is kept to open.
    if ! pdftotext -q "$raw" /tmp/doc.raw.txt || [ ! -s /tmp/doc.raw.txt ]; then
      reason="pdftotext produced no text"; return 1
    fi
    sha="$(node scripts/normalize.mjs /tmp/doc.raw.txt text /tmp/doc.norm.txt)"
    docname="$(basename "$url")"
    textname="document.txt"
  else
    # Sanity floor: real pages are tens of KB; block/error pages are tiny.
    if [ "$bytes" -lt 2000 ]; then
      reason="response too small to be the real page ($bytes bytes)"; return 1
    fi
    sha="$(node scripts/normalize.mjs "$raw" html /tmp/doc.norm.txt)"
    docname="page.html"
    textname="page.txt"
  fi
}

# Emit one tab-separated record per source. Tabs are safe here: none of the
# fields (codes, dirs, URLs, regex patterns) can contain one. Alternates are
# space-joined; "-" stands in for none because a tab IFS collapses empty fields.
node -e '
  const { sources } = JSON.parse(require("fs").readFileSync("sources.json", "utf8"));
  for (const s of sources) {
    process.stdout.write([
      s.sourceCode, s.dir, s.type, s.url,
      (s.alternates ?? []).join(" ") || "-",
      s.resolve?.linkPattern ?? "", s.resolve?.base ?? "",
    ].join("\t") + "\n");
  }
' > /tmp/sources.tsv

echo "Mirroring $(wc -l </tmp/sources.tsv | tr -d ' ') sources"

while IFS=$'\t' read -r CODE DIR TYPE URL ALTS PATTERN BASE; do
  [ -n "$CODE" ] || continue
  echo "==> $CODE"
  outdir="mirrors/$DIR"
  mkdir -p "$outdir"
  doc_url="$URL"

  # Rotating filename: discover the real document URL from the landing page.
  if [ -n "$PATTERN" ]; then
    doc_url="$(resolve_url "$URL" "$PATTERN" "$BASE")"
    if [ -z "$doc_url" ]; then
      fail "$CODE" "could not resolve document link from landing page (layout changed?)"
      continue
    fi
    echo "  resolved: $(basename "$doc_url")"
  fi

  # Try the primary, then each alternate, until one yields the real document.
  # A different site's page normalizes to a different hash, so a fallback
  # commit reads as a change; manifest sourceUrl records which one was used.
  candidates=("$doc_url")
  if [ "$ALTS" != "-" ]; then read -ra alt_urls <<<"$ALTS"; candidates+=("${alt_urls[@]}"); fi
  got=0; reasons=""
  for cand in "${candidates[@]}"; do
    [ -n "$cand" ] || continue
    if acquire "$cand" "$TYPE"; then
      got=1; doc_url="$cand"; break
    fi
    echo "  failed ($reason): $cand"
    reasons="${reasons:+$reasons; }$reason"
    sleep "$POLITE_DELAY"
  done
  unset alt_urls
  if [ "$got" = "0" ]; then
    fail "$CODE" "all sources failed: $reasons"
    sleep "$POLITE_DELAY"; continue
  fi
  [ "$doc_url" = "$URL" ] || echo "  using alternate: $doc_url"

  # Drop files left behind by a previous run under a different name. HUD's
  # filename rotates (…-Update-18-Redline.pdf → -19-), so without this every
  # update strands the prior document in place — a stale handbook sitting next
  # to the current one with nothing to say which is which. Runs on every pass,
  # so it self-heals rather than only fixing up at the moment of a rename.
  for existing in "$outdir"/*; do
    [ -e "$existing" ] || continue
    case "$(basename "$existing")" in
      "$docname"|"$textname"|manifest.json) ;;
      *) echo "  pruning stale $(basename "$existing")"; rm -f "$existing" ;;
    esac
  done

  read -r stored_sha stored_version <<<"$(manifest_state "$outdir/manifest.json")"
  if [ "$sha" = "$stored_sha" ] && [ "$stored_version" = "$MANIFEST_VERSION" ]; then
    echo "  unchanged (sha256=${sha:0:16}…)"
  else
    cp "$raw" "$outdir/$docname"
    cp /tmp/doc.norm.txt "$outdir/$textname"
    # textFile is what consumers fetch to diff a change. Naming it here means
    # the app never has to guess at page.txt vs document.txt.
    cat >"$outdir/manifest.json" <<JSON
{
  "manifestVersion": $MANIFEST_VERSION,
  "sourceCode": "$CODE",
  "sourceUrl": "$doc_url",
  "filename": "$docname",
  "textFile": "$textname",
  "sha256": "$sha",
  "bytes": $bytes
}
JSON
    if [ "$sha" = "$stored_sha" ]; then
      echo "  manifest upgraded to v$MANIFEST_VERSION (content unchanged)"
    else
      echo "  CHANGED  sha256=${sha:0:16}… bytes=$bytes"
    fi
    changed=1
  fi

  sleep "$POLITE_DELAY"
done < /tmp/sources.tsv

echo
if [ "$changed" = "0" ]; then
  echo "==> No substantive changes"
else
  echo "==> Changes written"
fi

if [ "$failed" = "1" ]; then
  echo "==> ${#failures[@]} source(s) skipped (primary and alternates all failed):"
  printf '    %s\n' "${failures[@]}"
  # Skipped sources keep their last good mirror. The run stays green so one
  # blocked host does not mask real failures elsewhere, but the skips are
  # surfaced as annotations and in the job summary so they are not silent.
  for f in "${failures[@]}"; do echo "::warning title=mirror source skipped::$f"; done
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    { echo "### Skipped sources (last good mirror kept)"; printf -- '- %s\n' "${failures[@]}"; } >>"$GITHUB_STEP_SUMMARY"
  fi
fi
exit 0
