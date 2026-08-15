#!/usr/bin/env node
/**
 * Normalize a fetched document to comparable text and print its SHA-256.
 *
 * This is what decides whether a run commits. Hashing raw bytes would commit
 * almost every day: government pages carry rotating nav, session tokens, and
 * "as of <today>" chrome, and each of those would surface in CondoGuard as a
 * false rule-change alert. Hashing normalized text means a commit happens only
 * when the substance moved.
 *
 * The HTML rules mirror normalizeHtml() in CondoGuard's
 * server/services/ruleWatcher.ts. Keep them in step: if the two drift, the app
 * and the mirror disagree about what counts as a change.
 *
 * usage: node scripts/normalize.mjs <file> <html|text> [outFile]
 *        prints the sha256 of the normalized text to stdout
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

function normalizeHtml(html) {
  return html
    .replace(/<script[\s\S]*?<\/script>/gi, " ")
    .replace(/<style[\s\S]*?<\/style>/gi, " ")
    .replace(/<!--[\s\S]*?-->/g, " ")
    .replace(/<[^>]+>/g, " ")
    .replace(/&nbsp;/gi, " ")
    .replace(/&amp;/gi, "&")
    .replace(/&lt;/gi, "<")
    .replace(/&gt;/gi, ">")
    .replace(/&#\d+;/g, " ")
    .replace(CHROME_DATE, " ")
    .replace(/\s+/g, " ")
    .trim();
}

/**
 * Text extracted from a PDF. Numeric revision markers like Fannie Mae's
 * "(08/06/2025)" are deliberately kept — those changing IS the signal.
 */
function normalizeText(text) {
  return text.replace(CHROME_DATE, " ").replace(/\s+/g, " ").trim();
}

const raw = readFileSync(file, "utf8");
const normalized = mode === "html" ? normalizeHtml(raw) : normalizeText(raw);

if (outFile) writeFileSync(outFile, normalized + "\n");
process.stdout.write(createHash("sha256").update(normalized).digest("hex"));
