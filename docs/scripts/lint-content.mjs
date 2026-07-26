// Checks the MDX under content/docs for the things a build cannot catch: banned voice,
// missing frontmatter, mermaid labels the renderer will choke on, and English/Japanese
// pages that have drifted apart.
//
//   node scripts/lint-content.mjs
//
// Exits non-zero on any error so CI and the local loop fail the same way.
import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join, relative } from 'node:path';

const ROOT = new URL('..', import.meta.url).pathname;
const CONTENT = join(ROOT, 'content/docs');

const errors = [];
const warnings = [];

function fail(file, message) {
  errors.push(`${file}: ${message}`);
}
function warn(file, message) {
  warnings.push(`${file}: ${message}`);
}

function walk(dir) {
  const out = [];
  for (const entry of readdirSync(dir)) {
    const full = join(dir, entry);
    if (statSync(full).isDirectory()) out.push(...walk(full));
    else if (entry.endsWith('.mdx')) out.push(full);
  }
  return out;
}

// Meta-commentary and marketing language. The docs describe the framework, never
// themselves, and never sell.
const BANNED = [
  /\bin this (?:article|page|section|guide|chapter),? we(?:'ll| will)?\b/i,
  /\bthis (?:page|section|document|guide) (?:carefully|thoroughly|comprehensively)\b/i,
  /\bwe have (?:carefully|thoroughly|comprehensively)\b/i,
  /\bas (?:summarised|summarized|described|explained) above\b/i,
  /\blet(?:'s| us) (?:dive|take a look|explore)\b/i,
  /\b(?:powerful|seamless|robust|blazing|cutting[- ]edge|state[- ]of[- ]the[- ]art|effortless|delightful)\b/i,
  /\bcomprehensive(?:ly)? (?:guide|documentation|reference|overview)\b/i,
  /この(?:記事|ページ|セクション|ドキュメント)では[^。]*(?:紹介|解説)します/,
  /(?:丁寧に|しっかりと|わかりやすく)(?:整理|まとめ|解説)しました/,
  /本(?:記事|稿|ドキュメント)では/,
  /いかがでしたか/,
];

const EMOJI = /[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}\u{FE0F}]/u;

function parseFrontmatter(src, file) {
  if (!src.startsWith('---\n')) {
    fail(file, 'missing frontmatter');
    return { body: src, data: {} };
  }
  const end = src.indexOf('\n---', 4);
  if (end === -1) {
    fail(file, 'unterminated frontmatter');
    return { body: src, data: {} };
  }
  const raw = src.slice(4, end);
  const data = {};
  for (const line of raw.split('\n')) {
    const m = line.match(/^([A-Za-z_]+):\s*(.*)$/);
    if (m) data[m[1]] = m[2].replace(/^['"]|['"]$/g, '').trim();
  }
  return { body: src.slice(end + 4), data };
}

// Everything a fenced ```mermaid block contains, so labels can be checked before the
// browser ever sees them.
function mermaidBlocks(body) {
  const blocks = [];
  const re = /```mermaid\n([\s\S]*?)```/g;
  let m;
  while ((m = re.exec(body)) !== null) blocks.push(m[1]);
  return blocks;
}

function checkMermaid(file, body) {
  for (const [i, chart] of mermaidBlocks(body).entries()) {
    const where = `mermaid block ${i + 1}`;
    const kind = chart.trim().split(/\s+/)[0];
    if (!/^(flowchart|graph|sequenceDiagram|stateDiagram-v2|classDiagram|erDiagram)$/.test(kind)) {
      warn(file, `${where}: unusual diagram type "${kind}"`);
    }

    for (const line of chart.split('\n')) {
      // Bracketed node labels: A[...], A(...), A{...}. Unquoted punctuation inside a
      // square-bracket label is the failure that shows up only at render time.
      for (const label of line.matchAll(/\[([^\]]*)\]/g)) {
        const text = label[1];
        if (text.startsWith('"') && text.endsWith('"')) continue;
        if (/[().:,{}<>#`|]/.test(text)) {
          fail(file, `${where}: unquoted label needs double quotes -> [${text}]`);
        }
      }
      if (/-->\|[^|]*[()][^|]*\|/.test(line)) {
        fail(file, `${where}: edge label contains parentheses -> ${line.trim()}`);
      }
    }
  }
}

const files = walk(CONTENT).sort();
if (files.length === 0) {
  console.error('no MDX found under content/docs');
  process.exit(1);
}

const byPage = new Map(); // page path -> { en, ja }

for (const full of files) {
  const file = relative(ROOT, full);
  const src = readFileSync(full, 'utf8');
  const { body, data } = parseFrontmatter(src, file);

  if (!data.title) fail(file, 'frontmatter is missing `title`');
  if (!data.description) fail(file, 'frontmatter is missing `description`');

  for (const pattern of BANNED) {
    const hit = body.match(pattern);
    if (hit) fail(file, `banned phrasing: "${hit[0].trim()}"`);
  }

  if (EMOJI.test(body)) fail(file, 'contains an emoji');

  if (/^import\s.+from\s/m.test(body)) {
    fail(file, 'MDX import statement; the components are provided globally');
  }

  // Locale-prefixed internal links break the other locale.
  const localeLink = body.match(/\]\(\/(?:en|ja)\//);
  if (localeLink) fail(file, 'internal link includes the locale prefix');

  checkMermaid(file, body);

  const stats = {
    file,
    headings: (body.match(/^##\s/gm) ?? []).length,
    code: (body.match(/^```/gm) ?? []).length / 2,
    mermaid: mermaidBlocks(body).length,
    chars: body.length,
  };

  if (stats.chars < 1200) fail(file, `too short (${stats.chars} chars) — this reads as a stub`);

  const key = full.replace(/\.ja\.mdx$/, '').replace(/\.mdx$/, '');
  const entry = byPage.get(key) ?? {};
  entry[full.endsWith('.ja.mdx') ? 'ja' : 'en'] = stats;
  byPage.set(key, entry);
}

for (const [key, pair] of byPage) {
  const page = relative(CONTENT, key);
  if (!pair.en) fail(page, 'has a Japanese page but no English one');
  if (!pair.ja) fail(page, 'has an English page but no Japanese translation');
  if (!pair.en || !pair.ja) continue;

  if (pair.en.headings !== pair.ja.headings) {
    fail(page, `heading count differs: en ${pair.en.headings} vs ja ${pair.ja.headings}`);
  }
  if (pair.en.code !== pair.ja.code) {
    fail(page, `code block count differs: en ${pair.en.code} vs ja ${pair.ja.code}`);
  }
  if (pair.en.mermaid !== pair.ja.mermaid) {
    fail(page, `mermaid count differs: en ${pair.en.mermaid} vs ja ${pair.ja.mermaid}`);
  }
}

const pages = [...byPage.values()].filter((p) => p.en);
const totalMermaid = pages.reduce((n, p) => n + p.en.mermaid, 0);
console.log(
  `checked ${files.length} files across ${byPage.size} pages ` +
    `(${totalMermaid} mermaid diagrams, ${pages.reduce((n, p) => n + p.en.code, 0)} code blocks)`,
);

for (const w of warnings) console.warn(`warn  ${w}`);
for (const e of errors) console.error(`error ${e}`);

if (errors.length > 0) {
  console.error(`\n${errors.length} problem(s)`);
  process.exit(1);
}
console.log('content OK');
