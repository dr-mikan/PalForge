import { createFromSource } from 'fumadocs-core/search/server';
import { source } from '@/lib/source';

export const revalidate = false;

// `staticGET` writes the whole index out at build time, which is what a static host can
// serve. The client fetches it once from components/search.tsx.
export const { staticGET: GET } = createFromSource(source, {
  localeMap: {
    ja: { language: undefined },
    en: { language: 'english' },
  },
});
