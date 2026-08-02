// Checks the MDX under content/docs for the things a build cannot catch: banned voice,
// missing frontmatter, mermaid labels the renderer will choke on, internal links that
// point at no page, and the three locales drifting apart.
//
//   node scripts/lint-content.mjs          (or: npm run lint:content, npm run lint:docs)
//
// Exits non-zero on any error so CI and the local loop fail the same way: it is wired to
// docs `prebuild` and to a step in .github/workflows/deploy-docs.yml that runs before the
// Next build, because a bad page should fail in seconds rather than after a full build.
//
// It also reads the Lua tree one directory up (../Scripts) to check the tool transcripts
// a page prints back at the reader — "running N suite(s)", "N classes, M lines" — against
// the code that produces them. Those checks are SKIPPED, not failed, when the Lua tree is
// not beside the docs, so this stays runnable on a docs-only checkout.
import { existsSync, readdirSync, readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join, relative } from 'node:path';

// fileURLToPath, not URL.pathname: on Windows the latter yields "/C:/..." and every
// join() below then addresses a directory that does not exist.
const ROOT = fileURLToPath(new URL('..', import.meta.url));
const CONTENT = join(ROOT, 'content/docs');
const REPO = join(ROOT, '..');

const errors = [];
const warnings = [];

function fail(file, message) {
  errors.push(`${file}: ${message}`);
}
function warn(file, message) {
  warnings.push(`${file}: ${message}`);
}

// withFileTypes, so a directory listing is one syscall and never a stat of a name that has
// already gone: an editor writing a page beside this one does it through a temp file, and
// a stat that raced it used to take the whole lint down with an ENOENT stack trace.
function walk(dir) {
  const out = [];
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const full = join(dir, entry.name);
    if (entry.isDirectory()) out.push(...walk(full));
    else if (entry.name.endsWith('.mdx')) out.push(full);
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

// Every fenced block, line by line rather than by regex, because a fence is allowed to be
// INDENTED (a code sample inside a list item — getting-started has two) and an anchored
// /^```/ counts neither its opener nor its closer. That miscount is silent: the block is
// invisible to the parity check, so a translation can drop it without the counts moving.
// Tracking the marker length also makes a ````-wrapped example containing ``` come out as
// one block instead of three.
function scanFences(body) {
  const blocks = [];
  let open = null;
  body.split('\n').forEach((raw, i) => {
    const m = raw.match(/^\s*(`{3,})(.*)$/);
    if (open === null) {
      if (m) open = { lang: m[2].trim().split(/\s+/)[0], marker: m[1].length, start: i + 1, lines: [] };
    } else if (m && m[1].length >= open.marker && m[2].trim() === '') {
      blocks.push(open);
      open = null;
    } else {
      open.lines.push(raw);
    }
  });
  return { blocks, unterminated: open ? open.start : null };
}

// The body with every fenced block removed and its lines blanked, so line numbers still
// point at the file. Prose checks run on this: a log transcript or a Lua sample is not
// prose and must not be read as untranslated English.
function stripFences(body) {
  const { blocks, unterminated } = scanFences(body);
  const lines = body.split('\n');
  for (const b of blocks) {
    for (let i = b.start - 1; i < b.start + b.lines.length + 1 && i < lines.length; i++) lines[i] = '';
  }
  // A fence that never closes swallows the rest of the file. Blank it too, so the report is
  // the one unterminated-fence error and not every prose check downstream of it.
  if (unterminated !== null) for (let i = unterminated - 1; i < lines.length; i++) lines[i] = '';
  return lines;
}

const mermaidBlocks = (body) =>
  scanFences(body).blocks.filter((b) => b.lang === 'mermaid').map((b) => b.lines.join('\n'));

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

//=============================================================================
// Transcripts checked against the code that prints them
//
// A page that quotes a tool's output is making a claim with a number in it, and that is
// the one kind of claim that goes stale without anyone touching the page: "13 suite(s)"
// and "18 classes, 223 lines" were both true once. Both numbers are DERIVED here from the
// source rather than written down a second time, so this cannot become a third place that
// drifts.
//
// Only VERBATIM TOOL OUTPUT is checked, never prose. `test.run("pal")` legitimately prints
// "running 1 suite(s)", a registry line legitimately says "19 class(es) registered", and a
// page may legitimately count a SUBSET of anything — so a bare "N suites" in a sentence is
// a warning at most, never an error. The prose counts that cannot be pinned this way
// ("294 checks", "16 channels") are left to the reader: the suite prints its own totals and
// they move with the world that is loaded, so there is no single right number to compare to.
//=============================================================================
function source(rel) {
  const full = join(REPO, rel);
  return existsSync(full) ? readFileSync(full, 'utf8') : null;
}

// #M.CASES in test/init.lua — the file's own header calls it "the AUTHORITATIVE suite
// count ... and nowhere else".
function suiteCount() {
  const src = source('Scripts/palforge/test/init.lua');
  if (!src) return null;
  const m = src.match(/M\.CASES\s*=\s*\{([\s\S]*?)\n\}/);
  return m ? (m[1].match(/"[^"]+"/g) ?? []).length : null;
}

// What tools/gen-types.lua prints after it writes: `wrote <path> (N classes, M lines, ...)`
// — N is its own count of ---@class lines, M is #out, i.e. the split length of the file.
function typesFile() {
  const src = source('Scripts/palforge/types.lua');
  if (!src) return null;
  return { classes: (src.match(/^---@class/gm) ?? []).length, lines: src.split('\n').length };
}

const SUITES = suiteCount();
const TYPES = typesFile();

function checkCounts(file, text) {
  if (SUITES !== null) {
    // The full-run line. The ": schema" tail is what makes it the FULL run: M.CASES is
    // ordered pure-suites-first and schema is always the head, so a partial run cannot
    // print this shape.
    for (const m of text.matchAll(/running\s+(\d+)\s+suite\(s\):\s*schema\b/g)) {
      if (Number(m[1]) !== SUITES) {
        fail(file, `sample output says "running ${m[1]} suite(s): schema, ..." — Scripts/palforge/test/init.lua M.CASES declares ${SUITES}`);
      }
    }
    // Prose. A subset count is a real thing to write, so this only warns.
    for (const m of text.matchAll(/(\d+)\s*(?:\*\*)?\s*(?:個|つ)?\s*の?\s*(?:test\s+|テスト)?(?:suites?|スイート|套件)/gi)) {
      const n = Number(m[1]);
      if (n >= 2 && n !== SUITES) {
        warn(file, `"${m[0].trim()}" — M.CASES declares ${SUITES} suites; check this is a deliberate subset`);
      }
    }
  }

  if (TYPES) {
    for (const m of text.matchAll(/types\.lua[^(\n]*\((\d+)\s+class(?:es)?,\s*(\d+)\s+lines?/g)) {
      if (Number(m[1]) !== TYPES.classes || Number(m[2]) !== TYPES.lines) {
        fail(file, `sample output says types.lua is "${m[1]} classes, ${m[2]} lines" — the generated Scripts/palforge/types.lua has ${TYPES.classes} classes and ${TYPES.lines} lines`);
      }
    }
  }
}

//=============================================================================
// A translation that is still in English
//
// Not "does this line contain Latin letters" — every page here is full of identifiers,
// and headings ARE API names. What is being caught is a RUN of PROSE: consecutive body
// lines with no CJK at all, after code fences, inline code, link targets and everything
// inside a JSX component are removed. The longest such run in the tree when this was
// written was 26 characters (a heading spelled `material、color、texture`), so the
// threshold has a lot of room and only a paragraph nobody translated reaches it.
//
// Inside a component is exempt on purpose, and not only because a `<TypeTable>` prop is
// quoted engine output: the index carries the single-player warning in English inside a
// <Callout> with the Japanese underneath it, and a statement quoted verbatim beside its
// translation is a correct page, not a drifted one.
//=============================================================================
const CJK = /[぀-ヿ㐀-䶿一-鿿＀-￯]/;
const ENGLISH_RUN = 120;

function checkTranslated(file, body) {
  let run = 0;
  let runStart = 0;
  let reported = false;
  let depth = 0;
  stripFences(body).forEach((raw, i) => {
    if (reported) return;
    const inComponent = depth > 0;
    depth = Math.max(0, depth
      + (raw.match(/<[A-Z][^>]*[^/>]>/g) ?? []).length
      - (raw.match(/<\/[A-Z][^>]*>/g) ?? []).length);
    // Any tag or brace on the line itself: a JSX element or a prop object, never prose.
    // Ambiguity resets the run — this must never invent a failure.
    if (inComponent || /[<>{}]/.test(raw)) {
      run = 0;
      return;
    }
    const line = raw
      .replace(/`[^`]*`/g, ' ')
      .replace(/\]\([^)]*\)/g, '] ')
      .replace(/https?:\/\/\S+/g, ' ');
    const latin = (line.match(/[A-Za-z]/g) ?? []).length;
    if (CJK.test(line) || latin === 0) {
      run = 0;
      return;
    }
    if (run === 0) runStart = i + 1;
    run += latin;
    if (run >= ENGLISH_RUN) {
      // One report per file: the first paragraph is enough to send someone to the page,
      // and a page copied wholesale would otherwise print fifty identical lines.
      fail(file, `line ${runStart}: ${run}+ characters of English prose with no CJK — this locale's page is a translation, not a copy`);
      reported = true;
    }
  });
}

const files = walk(CONTENT).sort();
if (files.length === 0) {
  console.error('no MDX found under content/docs');
  process.exit(1);
}

const byPage = new Map(); // page path -> { en, ja, zh }

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

  // Locale-prefixed internal links break the other locale. All three locale codes, not
  // two: /zh/ is as wrong in a link as /ja/ and was the one the list forgot.
  const localeLink = body.match(/\]\(\/(?:en|ja|zh)\//);
  if (localeLink) fail(file, `internal link includes the locale prefix: ${localeLink[0]}`);

  // Where an absolute internal link actually lands. The route is /<lang>/docs/<slug>
  // (app/[lang]/docs/[[...slug]]), the locale is added by the router, so every link a page
  // writes starts /docs/ and has to name a page that exists. A dead cross-link renders
  // fine and 404s on click, which is exactly the kind of break a restructure leaves behind.
  for (const m of body.matchAll(/\]\((\/[^)\s#]*)(#[^)\s]*)?\)/g)) {
    const target = m[1].replace(/\/$/, '');
    if (!target.startsWith('/docs')) {
      fail(file, `internal link does not start with /docs: ${target}`);
      continue;
    }
    const slug = target.slice('/docs'.length).replace(/^\//, '') || 'index';
    if (!existsSync(join(CONTENT, `${slug}.mdx`)) && !existsSync(join(CONTENT, slug, 'index.mdx'))) {
      fail(file, `internal link points at no page: ${target}`);
    }
  }

  checkMermaid(file, body);
  checkCounts(file, body);

  const locale = full.match(/\.([a-z]{2})\.mdx$/)?.[1] ?? 'en';
  if (locale !== 'en') checkTranslated(file, body);

  const fences = scanFences(body);
  if (fences.unterminated !== null) {
    fail(file, `unterminated code fence opened at line ${fences.unterminated} — every count below it is wrong`);
  }
  const stripped = stripFences(body).join('\n');

  // A page opens by telling the reader what they will be able to do, and closes by
  // recapping it — both as H2s, the first and last on the page.
  const h2s = [...stripped.matchAll(/^##\s+(.+?)\s*$/gm)].map((m) => m[1].trim());
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

  // Counted on the fence-stripped body so a `## ` inside a shell or markdown sample is not
  // read as a section, and PER LEVEL: an H2 count that matches while the translation is
  // three H3s short is the drift this is here to catch.
  const stats = {
    file,
    headings: (stripped.match(/^##\s/gm) ?? []).length,
    h3: (stripped.match(/^###\s/gm) ?? []).length,
    h4: (stripped.match(/^####\s/gm) ?? []).length,
    code: fences.blocks.length,
    mermaid: mermaidBlocks(body).length,
    chars: body.length,
  };

  if (stats.chars < 1200) fail(file, `too short (${stats.chars} chars) — this reads as a stub`);

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
      ['H2 heading', 'headings'],
      ['H3 heading', 'h3'],
      ['H4 heading', 'h4'],
      ['code block', 'code'],
      ['mermaid', 'mermaid'],
    ]) {
      if (group.en[field] !== group[locale][field]) {
        fail(page, `${what} count differs: en ${group.en[field]} vs ${locale} ${group[locale][field]}`);
      }
    }
  }
}

//=============================================================================
// The sidebar. meta.json orders the pages and meta.<locale>.json translates it, so the
// `pages` arrays are the SAME list in a different language — a page added to one locale's
// nav and not the others is reachable in one language only, and a name that matches no
// file is a sidebar entry that 404s. Neither shows up in the .mdx parity counts above.
//=============================================================================
function metaGroups(dir) {
  const out = [];
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    if (entry.isDirectory()) out.push(...metaGroups(join(dir, entry.name)));
  }
  if (existsSync(join(dir, 'meta.json'))) out.push(dir);
  return out;
}

// A `pages` entry is a page name only when it is a plain slug. Everything else fumadocs
// accepts there is a directive about layout rather than a file: "..." / "z...a" (include
// the rest), "---Label---" (separator), "[Name](url)" (link), "(group)", "!name" (exclude).
const named = (meta) => (meta.pages ?? []).filter((p) => typeof p === 'string' && /^[\w-]+(?:\/[\w-]+)*$/.test(p));
const hasRest = (meta) => (meta.pages ?? []).some((p) => typeof p === 'string' && p.startsWith('...'));

for (const dir of metaGroups(CONTENT)) {
  const where = relative(CONTENT, dir) || '.';
  const read = (name) => {
    const full = join(dir, name);
    if (!existsSync(full)) return null;
    try {
      return JSON.parse(readFileSync(full, 'utf8'));
    } catch (err) {
      fail(`${where}/${name}`, `is not valid JSON: ${err.message}`);
      return null;
    }
  };
  const en = read('meta.json');
  if (!en) continue;

  for (const name of named(en)) {
    const ok = existsSync(join(dir, `${name}.mdx`)) || existsSync(join(dir, name, 'meta.json'));
    if (!ok) fail(`${where}/meta.json`, `lists "${name}", which is neither a page nor a section here`);
  }
  for (const locale of LOCALES) {
    if (locale === 'en') continue;
    const other = read(`meta.${locale}.json`);
    if (!other) {
      fail(`${where}/meta.${locale}.json`, 'is missing; the sidebar would fall back to English');
      continue;
    }
    if (!other.title) fail(`${where}/meta.${locale}.json`, 'has no title');
    const a = JSON.stringify(named(en));
    const b = JSON.stringify(named(other));
    if (a !== b) fail(`${where}/meta.${locale}.json`, `page order differs from meta.json: ${a} vs ${b}`);
  }
}

// Every page has to be reachable from the nav. A meta.json that names its pages explicitly
// SELECTS them: an .mdx left out of the list is built and routable and appears in no
// sidebar. (A "..." entry pulls in the rest, so a directory that has one cannot orphan
// anything and is skipped here.)
const listed = new Set();
const openDirs = new Set();
for (const dir of metaGroups(CONTENT)) {
  let meta;
  try {
    meta = JSON.parse(readFileSync(join(dir, 'meta.json'), 'utf8'));
  } catch {
    continue; // already reported as invalid JSON above
  }
  if (hasRest(meta)) openDirs.add(dir);
  for (const name of named(meta)) listed.add(join(dir, name));
}
for (const [key] of byPage) {
  if (!listed.has(key) && !openDirs.has(dirname(key))) {
    fail(relative(CONTENT, key), 'is not listed in any meta.json — it is built, but nothing in the sidebar reaches it');
  }
}

const pages = [...byPage.values()].filter((p) => p.en);
const totalMermaid = pages.reduce((n, p) => n + p.en.mermaid, 0);
console.log(
  `checked ${files.length} files across ${byPage.size} pages ` +
    `(${totalMermaid} mermaid diagrams, ${pages.reduce((n, p) => n + p.en.code, 0)} code blocks` +
    `${SUITES === null || !TYPES ? ', Lua tree not found — transcript counts skipped' : ''})`,
);

for (const w of warnings) console.warn(`warn  ${w}`);
for (const e of errors) console.error(`error ${e}`);

if (errors.length > 0) {
  console.error(`\n${errors.length} problem(s)`);
  process.exit(1);
}
console.log('content OK');
