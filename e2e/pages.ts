// Every documented route, kept in one place so the specs below and the link crawl agree.
export const LOCALES = ['en', 'ja'] as const;

export const DOC_SLUGS = [
  '',
  'getting-started',
  'concepts/definitions',
  'concepts/schema',
  'concepts/lifecycle',
  'concepts/editor-setup',
  'api/pal',
  'api/item',
  'api/building',
  'api/skill',
  'api/effect',
  'api/audio',
  'api/mesh',
  'api/ui',
  'api/player',
  'guides/first-content-pack',
  'guides/testing',
] as const;

// Empty against the local static server, `/PalForge` against GitHub Pages. Set
// DOCS_BASE_PATH together with DOCS_BASE_URL to point the suite at the published site.
export const BASE = process.env.DOCS_BASE_PATH ?? '';

export function siteUrl(path: string): string {
  return `${BASE}${path}`;
}

export function docUrl(locale: string, slug: string): string {
  return siteUrl(slug ? `/${locale}/docs/${slug}/` : `/${locale}/docs/`);
}
