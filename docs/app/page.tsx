import type { Metadata } from 'next';
import { appName, basePath } from '@/lib/shared';

const target = `${basePath}/en`;

export const metadata: Metadata = {
  title: appName,
  robots: { index: false, follow: true },
};

// `output: export` cannot emit a server redirect, so the entry page is a static document
// that bounces to the default locale and still works with JavaScript disabled.
export default function Page() {
  return (
    <html lang="en">
      <head>
        <meta httpEquiv="refresh" content={`0; url=${target}`} />
        <link rel="canonical" href={target} />
      </head>
      <body>
        <p>
          Redirecting to <a href={target}>{appName}</a>.
        </p>
      </body>
    </html>
  );
}
