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
    // Numeric entities in both decimal (&#8195;) and hex (&#x2003;) form. Only
    // decimal was handled before, so hex em-spaces survived into the diff.
    .replace(/&#(?:\d+|[xX][0-9a-fA-F]+);/g, " ");
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
