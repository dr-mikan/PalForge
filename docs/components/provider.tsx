'use client';
import SearchDialog from '@/components/search';
import { RootProvider } from 'fumadocs-ui/provider/next';
import { type ReactNode } from 'react';
import { provider } from '@/lib/i18n';

export function Provider({ locale, children }: { locale: string; children: ReactNode }) {
  return (
    <RootProvider i18n={provider(locale)} search={{ SearchDialog }}>
      {children}
    </RootProvider>
  );
}
