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

  // Design history and API archaeology. The reader never saw the old shape, so telling
  // them what it is NOT only teaches them a name that does not exist.
  /\b(?:Pal|Item|Building|Skill|Effect|Audio|Mesh|UI)\.define\b/,
  /\bthe module (?:itself )?is the constructor\b/i,
  /\bcalling the module IS defining\b/i,
  /\b(?:used to be|previously (?:called|named)|was renamed|has been renamed|no longer exists)\b/i,
  /モジュール自体が(?:コンストラクタ|定義)/,
  /(?:以前は|かつては|旧|従来)[^。]{0,20}(?:でした|呼ばれ|という名|form)/,
  /(?:改名|リネーム)(?:されました|しました)/,
  /本(?:文|页|章)(?:中|里)?(?:我们|将)/,
  /(?:以前|原来|过去)(?:叫做|称为|是)/,
  /(?:已)?(?:重命名|更名)(?:为|成)/,
];

// The two structural sections every page carries, in both languages.
const INTRO_HEADINGS = [
  'What you can do after this page',
  'このページでできるようになること',
  '读完本页你可以做到',
];
const SUMMARY_HEADINGS = ['Summary', 'まとめ', '小结'];

// Every page exists in all three. `en` is the source of truth for structure.
const LOCALES = ['en', 'ja', 'zh'];

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

  // A page opens by telling the reader what they will be able to do, and closes by
  // recapping it — both as H2s, the first and last on the page.
  const h2s = [...body.matchAll(/^##\s+(.+?)\s*$/gm)].map((m) => m[1].trim());
  if (h2s.length === 0) {
    fail(file, 'has no H2 sections');
  } else {
    if (!INTRO_HEADINGS.includes(h2s[0])) {
      fail(file, `first section must be one of ${INTRO_HEADINGS.map((h) => `"${h}"`).join(' / ')}, got "${h2s[0]}"`);
    }
    if (!SUMMARY_HEADINGS.includes(h2s[h2s.length - 1])) {
      fail(file, `last section must be one of ${SUMMARY_HEADINGS.map((h) => `"${h}"`).join(' / ')}, got "${h2s[h2s.length - 1]}"`);
    }
  }

  const stats = {
    file,
    headings: (body.match(/^##\s/gm) ?? []).length,
    code: (body.match(/^```/gm) ?? []).length / 2,
    mermaid: mermaidBlocks(body).length,
    chars: body.length,
  };

  if (stats.chars < 1200) fail(file, `too short (${stats.chars} chars) — this reads as a stub`);

  const localeMatch = full.match(/\.([a-z]{2})\.mdx$/);
  const locale = localeMatch ? localeMatch[1] : 'en';
  const key = full.replace(/(\.[a-z]{2})?\.mdx$/, '');
  const entry = byPage.get(key) ?? {};
  entry[locale] = stats;
  byPage.set(key, entry);
}

for (const [key, group] of byPage) {
  const page = relative(CONTENT, key);
  if (!group.en) {
    fail(page, 'has a translation but no English source');
    continue;
  }
  for (const locale of LOCALES) {
    if (locale === 'en') continue;
    if (!group[locale]) {
      fail(page, `is missing its ${locale} translation`);
      continue;
    }
    for (const [what, field] of [
      ['heading', 'headings'],
      ['code block', 'code'],
      ['mermaid', 'mermaid'],
    ]) {
      if (group.en[field] !== group[locale][field]) {
        fail(page, `${what} count differs: en ${group.en[field]} vs ${locale} ${group[locale][field]}`);
      }
    }
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
