import { notFound } from 'next/navigation';
import { englishPages, source } from '@/lib/source';

// Serves the raw English Markdown behind every page's "Copy as Markdown" button, as a static
// file. `output: export` cannot run a route at request time, so each page's Markdown is
// written out at build time under /md/docs/<slug>/content.md.
export const dynamic = 'force-static';
export const revalidate = false;

export async function GET(_req: Request, props: { params: Promise<{ slug: string[] }> }) {
  const { slug } = await props.params;

  // The last segment is always the filename; what precedes it is the page's slug.
  if (slug.length === 0 || slug[slug.length - 1] !== 'content.md') notFound();
  const pageSlugs = slug.slice(0, -1);

  const page = source.getPage(pageSlugs, 'en');
  if (!page) notFound();

  const body = await page.data.getText('processed');
  const text = `# ${page.data.title}\n\n${page.data.description ?? ''}\n\n${body}`;

  return new Response(text, {
    headers: { 'Content-Type': 'text/markdown; charset=utf-8' },
  });
}

export function generateStaticParams() {
  return englishPages().map((page) => ({ slug: [...page.slugs, 'content.md'] }));
}
