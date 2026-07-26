import { docs } from 'collections/server';
import { loader } from 'fumadocs-core/source';
import { i18n } from './i18n';
import { basePath, docsRoute } from './shared';

export const source = loader({
  baseUrl: docsRoute,
  i18n,
  source: docs.toFumadocsSource(),
});

export type Source = typeof source;

// The raw-Markdown route. "Copy as Markdown" always hands over the ENGLISH text, whatever
// locale the reader is on: the copy is nearly always going into a coding assistant, and the
// API names, error strings and code in this documentation are English either way.
export const MARKDOWN_ROUTE = '/md/docs';

/**
 * Segments and URL of the English Markdown for a page. `slugs` is the page's own slug list,
 * which is locale-independent — /ja/docs/api/pal and /docs/api/pal share it.
 */
export function markdownFor(slugs: readonly string[]) {
  const segments = [...slugs, 'content.md'];
  return {
    segments,
    url: `${basePath}${MARKDOWN_ROUTE}/${segments.join('/')}`,
  };
}

/** Every English page, for the static Markdown route to enumerate. */
export function englishPages() {
  return source.getPages('en');
}
