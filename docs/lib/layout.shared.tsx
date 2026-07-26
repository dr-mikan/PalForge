import type { BaseLayoutProps } from 'fumadocs-ui/layouts/shared';
import { appName, githubUrl } from './shared';
import { i18n } from './i18n';

export function baseOptions(locale: string): BaseLayoutProps {
  return {
    i18n,
    nav: {
      title: (
        <>
          <span className="font-bold tracking-tight">{appName}</span>
        </>
      ),
      url: `/${locale}`,
    },
    githubUrl,
  };
}
