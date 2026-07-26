import { docs } from 'collections/server';
import { loader } from 'fumadocs-core/source';
import { i18n } from './i18n';
import { docsRoute } from './shared';

export const source = loader({
  baseUrl: docsRoute,
  i18n,
  source: docs.toFumadocsSource(),
});

export type Source = typeof source;
