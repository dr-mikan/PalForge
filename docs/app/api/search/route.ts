import { createFromSource } from 'fumadocs-core/search/server';
import { source } from '@/lib/source';

export const revalidate = false;

// `staticGET` writes the whole index out at build time, which is what a static host can
// serve. The client fetches it once from components/search.tsx.
export const { staticGET: GET } = createFromSource(source, {
  localeMap: {
    // Orama ships no Japanese or Chinese tokenizer here; the default splitter still indexes
    // the Latin API names, which is what a reader searches a Lua reference for.
    ja: { language: undefined },
    zh: { language: undefined },
    en: { language: 'english' },
  },
});
