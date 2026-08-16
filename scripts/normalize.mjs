#!/usr/bin/env node
/**
 * Normalize a fetched document into (a) readable text for diffing and
 * (b) a SHA-256 over its collapsed form for change detection.
 *
 * Two outputs, deliberately:
 *
 *   - The TEXT keeps line structure. Block-level tags become newlines so that
 *     `git diff` — and CondoGuard's change-event view — show which paragraph
 *     moved. Collapsing everything to one line, as this script first did, makes
 *     a 546 KB single-line file whose diff is useless to a human.
 *   - The HASH is taken over the fully collapsed text, so a reflow that only
 *     changes where lines break is NOT reported as a rule change.
 *
 * The stripping rules mirror normalizeHtml() in CondoGuard's
 * server/services/ruleWatcher.ts. Keep them in step: if they drift, the app and
 * the mirror disagree about what counts as a change.
 *
 * usage: node scripts/normalize.mjs <file> <html|text> [outFile]
 *        prints the sha256 of the collapsed text to stdout
 */
import { readFileSync, writeFileSync } from "node:fs";
import { createHash } from "node:crypto";

const [, , file, mode, outFile] = process.argv;
if (!file || !["html", "text"].includes(mode ?? "")) {
  console.error("usage: normalize.mjs <file> <html|text> [outFile]");
  process.exit(2);
}

/** Long-form dates ("July 9, 2026") are page chrome, not rule content. */
const CHROME_DATE =
  /\b(?:January|February|March|April|May|June|July|August|September|October|November|December)\s+\d{1,2},\s+\d{4}\b/gi;

/** HTML → readable text, one block element per line. */
function htmlToText(html) {
  return html
    // <title> is chrome, and on law.lis.virginia.gov it is actively wrong: the
    // page for § 55.1-1965 has served <title>§ 52-11. Defense of police
    // officers</title>, rotating between runs and firing a daily false change.
    // No revision signal lives here — Fannie Mae's "(08/05/2026)" marker is in
    // the body, not the title — so dropping it costs nothing.
    .replace(/<title[\s\S]*?<\/title>/gi, " ")
    .replace(/<script[\s\S]*?<\/script>/gi, " ")
    .replace(/<style[\s\S]*?<\/style>/gi, " ")
    .replace(/<!--[\s\S]*?-->/g, " ")
    // Block boundaries become newlines BEFORE tags are stripped, so the text
    // keeps the document's paragraph structure instead of running together.
    .replace(/<br\s*\/?>/gi, "\n")
    .replace(/<\/(p|div|li|tr|h[1-6]|section|article|td|th)\s*>/gi, "\n")
    .replace(/<[^>]+>/g, " ")
    .replace(/&nbsp;/gi, " ")
    .replace(/&amp;/gi, "&")
    .replace(/&lt;/gi, "<")
    .replace(/&gt;/gi, ">")
    // Named entities statutes actually use. Left undecoded they show up
    // literally in the diff a reviewer reads (&raquo; in Virginia's breadcrumb,
    // &sect; throughout). Anything unrecognized becomes a space below.
    .replace(/&sect;/gi, "\u00a7")
    .replace(/&raquo;/gi, "\u00bb")
    .replace(/&laquo;/gi, "\u00ab")
    .replace(/&mdash;/gi, "\u2014")
    .replace(/&ndash;/gi, "\u2013")
    .replace(/&hellip;/gi, "\u2026")
    .replace(/&bull;/gi, "\u2022")
    .replace(/&middot;/gi, "\u00b7")
    .replace(/&deg;/gi, "\u00b0")
    .replace(/&copy;/gi, "\u00a9")
    .replace(/&(?:quot|ldquo|rdquo);/gi, '"')
    .replace(/&(?:apos|lsquo|rsquo);/gi, "'")
    // Numeric entities in both decimal (&#8195;) and hex (&#x2003;) form. Only
    // decimal was handled before, so hex em-spaces survived into the diff.
    .replace(/&#(?:\d+|[xX][0-9a-fA-F]+);/g, " ")
    // Any remaining named entity: drop rather than leave raw markup in a diff.
    .replace(/&[a-zA-Z][a-zA-Z0-9]{1,10};/g, " ");
}

/** Tidy per line, drop blank runs. Numeric revision markers are kept. */
function tidy(text) {
  return text
    .replace(CHROME_DATE, " ")
    .split("\n")
    .map((line) => line.replace(/[ \t ]+/g, " ").trim())
    .filter((line) => line.length > 0)
    .join("\n")
    .trim();
}

const raw = readFileSync(file, "utf8");
const readable = tidy(mode === "html" ? htmlToText(raw) : raw);

// The hash ignores line breaks entirely: only substance counts as a change.
const collapsed = readable.replace(/\s+/g, " ").trim();

if (outFile) writeFileSync(outFile, readable + "\n");
process.stdout.write(createHash("sha256").update(collapsed).digest("hex"));
