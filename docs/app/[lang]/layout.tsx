import type { ReactNode } from 'react';
import { Inter } from 'next/font/google';
import { Provider } from '@/components/provider';
import { i18n } from '@/lib/i18n';
import { appName, appTagline } from '@/lib/shared';
import type { Metadata } from 'next';

const inter = Inter({ subsets: ['latin'] });

export const metadata: Metadata = {
  title: { default: appName, template: `%s | ${appName}` },
  description: appTagline,
};

export function generateStaticParams() {
  return i18n.languages.map((lang) => ({ lang }));
}

export default async function LangLayout({
  params,
  children,
}: {
  params: Promise<{ lang: string }>;
  children: ReactNode;
}) {
  const { lang } = await params;

  return (
    <html lang={lang} className={inter.className} suppressHydrationWarning>
      <body className="flex min-h-screen flex-col">
        <Provider locale={lang}>{children}</Provider>
      </body>
    </html>
  );
}
