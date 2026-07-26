import { createMDX } from 'fumadocs-mdx/next';

const withMDX = createMDX();

// GitHub Pages serves a project site under /<repo>. Set NEXT_PUBLIC_BASE_PATH in CI;
// locally it stays empty so `next dev` and the Playwright run work at the root.
const basePath = process.env.NEXT_PUBLIC_BASE_PATH ?? '';

/** @type {import('next').NextConfig} */
const config = {
  output: 'export',
  // The repo root has its own lockfile (Playwright); pin the workspace so Turbopack does
  // not walk up and pick that one.
  turbopack: { root: import.meta.dirname },
  reactStrictMode: true,
  basePath,
  trailingSlash: true,
  images: { unoptimized: true },
};

export default withMDX(config);
