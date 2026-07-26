'use client';

import { useEffect, useId, useRef, useState } from 'react';
import { useTheme } from 'next-themes';

// Mermaid renders in the browser, so the chart source arrives as a string and the SVG is
// produced after mount. The theme is re-read on every change, otherwise a diagram drawn in
// light mode stays unreadable after the user flips to dark.
export function Mermaid({ chart }: { chart: string }) {
  const id = useId().replace(/[^a-zA-Z0-9]/g, '');
  const containerRef = useRef<HTMLDivElement>(null);
  const [svg, setSvg] = useState('');
  const [error, setError] = useState<string | null>(null);
  const { resolvedTheme } = useTheme();

  useEffect(() => {
    let cancelled = false;

    async function render() {
      const { default: mermaid } = await import('mermaid');

      mermaid.initialize({
        startOnLoad: false,
        securityLevel: 'strict',
        fontFamily: 'inherit',
        theme: resolvedTheme === 'dark' ? 'dark' : 'default',
      });

      try {
        const { svg } = await mermaid.render(`mermaid-${id}`, chart.trim());
        if (!cancelled) {
          setSvg(svg);
          setError(null);
        }
      } catch (e) {
        if (!cancelled) setError(e instanceof Error ? e.message : String(e));
      }
    }

    void render();
    return () => {
      cancelled = true;
    };
  }, [chart, id, resolvedTheme]);

  if (error) {
    return (
      <pre className="fd-mermaid-error overflow-x-auto rounded-lg border border-red-500/40 bg-red-500/5 p-4 text-sm">
        {error}
      </pre>
    );
  }

  return (
    <div
      ref={containerRef}
      data-mermaid=""
      className="fd-mermaid my-6 flex justify-center overflow-x-auto rounded-lg border bg-fd-card p-4 [&_svg]:max-w-full"
      dangerouslySetInnerHTML={{ __html: svg }}
    />
  );
}
