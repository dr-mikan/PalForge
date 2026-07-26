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
] as const;

export function docUrl(locale: string, slug: string): string {
  return slug ? `/${locale}/docs/${slug}/` : `/${locale}/docs/`;
}
