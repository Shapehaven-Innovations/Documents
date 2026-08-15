# Documents

Public document host for Shapehaven applications. Contents are public-domain
government publications mirrored so applications can watch them for changes.

This repo must stay **public**: consumers read it over
`raw.githubusercontent.com`, and a private repo would require shipping an access
token inside a locally installed desktop app.

## CondoGuard rule source mirror

CondoGuard watches the lender and state publications behind its compliance rule
catalog. Two of them cannot be fetched directly.

hud.gov sits behind Cloudflare and answers **403 to every non-browser client**
tested from a normal network — curl (default UA, Chrome UA, HTTP/1.1, full
ordered header set), wget, python urllib, and Node `fetch`. The Wayback Machine
fallback used previously now answers **429** on every request, including its
availability API. Both HUD sources were silently failing for a month.

GitHub Actions runners are **not** blocked. Verified 2026-08-15:

```
http=200 size=11384374
hud.pdf: PDF document, version 1.7 (zip deflate encoded)
00000000: 2550 4446 2d31 2e37    %PDF-1.7
```

So `.github/workflows/mirror.yml` runs monthly, fetches from a runner, and
commits the documents plus a small manifest. CondoGuard watches the manifest.

### Layout

```
mirrors/hud-4000-1/manifest.json   HUD SFH Handbook 4000.1 — hash + metadata
mirrors/hud-4000-1/handbook.pdf    the handbook itself
mirrors/hud-condo/manifest.json    HUD FHA Condominiums page
mirrors/hud-condo/page.html
```

Consumers watch `manifest.json`, not the document: ~200 bytes per check instead
of 11.4 MB, and `raw.githubusercontent.com` honors ETag/If-None-Match properly
(hud.gov sent neither header).

### Design notes

**The manifest carries no timestamps.** A `fetchedAt` field would change the
hash on every run and fire a false "publication changed" alert every month. Only
stable fields are written: `sourceCode`, `sourceUrl`, `filename`, `sha256`,
`bytes`.

**Nothing is committed unless it validates.** `curl -O` writes a 403 error page
to disk just as happily as a real PDF — that is exactly how a 4.5 KB HTML file
ends up named `handbook.pdf`. Every fetch is checked (HTTP status, `%PDF` magic
bytes, minimum size for HTML) and the script exits non-zero rather than
overwriting a good manifest with garbage. A failed run leaves the last known
good mirror in place and shows as a red workflow run.

**Filenames are resolved, not hardcoded.** HUD ships versioned names
(`40001-hsgh-Update-18-Redline.pdf`), so a fixed URL freezes at Update 18
forever and reports "no changes" indefinitely. The script scrapes the current
name from the landing page each run.

### First run

Actions → **mirror-rule-sources** → Run workflow. Then confirm
`mirrors/hud-4000-1/manifest.json` resolves over `raw.githubusercontent.com` and
run `pnpm db:seed` in CondoGuard to re-point the two HUD sources.

The consuming URL is built from a single constant, `RULE_MIRROR_BASE` in
CondoGuard's `server/seeds/ruleSources.ts` — update it if this repo moves.

### Not covered

`capitol.hawaii.gov` returns 403 even from a runner, so CondoGuard's
`HI_RESERVE_STUDY` rule has no watched source and needs manual review.
