import type { ComponentProps, ReactElement } from 'react';
import defaultMdxComponents from 'fumadocs-ui/mdx';
import { Callout } from 'fumadocs-ui/components/callout';
import { Tab, Tabs } from 'fumadocs-ui/components/tabs';
import { Step, Steps } from 'fumadocs-ui/components/steps';
import { Accordion, Accordions } from 'fumadocs-ui/components/accordion';
import { TypeTable } from 'fumadocs-ui/components/type-table';
import { Card, Cards } from 'fumadocs-ui/components/card';
import { Mermaid } from '@/components/mermaid';
import type { MDXComponents } from 'mdx/types';

// Pages are written once and served under every locale, so their internal links are
// locale-free (`/docs/api/pal`). Anything that renders an href gets the active locale
// spliced in here rather than in the content.
function localise(href: string | undefined, locale: string): string | undefined {
  if (!href || !href.startsWith('/docs')) return href;
  return `/${locale}${href}`;
}

const DefaultAnchor = defaultMdxComponents.a as (props: ComponentProps<'a'>) => ReactElement;

export function getMDXComponents(locale: string, components?: MDXComponents) {
  const Anchor = (props: ComponentProps<'a'>) => (
    <DefaultAnchor {...props} href={localise(props.href, locale)} />
  );

  const LocaleCard = (props: ComponentProps<typeof Card>) => (
    <Card {...props} href={localise(props.href, locale)} />
  );

  return {
    ...defaultMdxComponents,
    a: Anchor,
    Callout,
    Tab,
    Tabs,
    Step,
    Steps,
    Accordion,
    Accordions,
    TypeTable,
    Card: LocaleCard,
    Cards,
    Mermaid,
    ...components,
  } satisfies MDXComponents;
}
