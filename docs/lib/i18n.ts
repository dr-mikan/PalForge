import { defineI18nUI } from 'fumadocs-ui/i18n';
import type { I18nConfig } from 'fumadocs-core/i18n';

export const i18n: I18nConfig = {
  defaultLanguage: 'en',
  languages: ['en', 'ja'],
  // Every locale keeps its prefix (/en, /ja) so a static host needs no rewrites.
  hideLocale: 'never',
  // Content files are `page.mdx` (en) and `page.ja.mdx` (ja).
  parser: 'dot',
};

export const { provider } = defineI18nUI(i18n, {
  en: { displayName: 'English' },
  ja: {
    displayName: '日本語',
    search: '検索',
    searchNoResult: '該当する項目がありません',
    toc: '目次',
    tocNoHeadings: '見出しがありません',
    lastUpdate: '最終更新',
    chooseLanguage: '言語',
    nextPage: '次のページ',
    previousPage: '前のページ',
    chooseTheme: 'テーマ',
    editOnGithub: 'GitHub で編集',
  },
});
