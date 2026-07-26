export const appName = 'PalForge';
export const appTagline = 'A content framework for Palworld';
export const docsRoute = '/docs';

export const gitConfig = {
  user: 'dr-mikan',
  repo: 'PalForge',
  branch: 'main',
};

export const githubUrl = `https://github.com/${gitConfig.user}/${gitConfig.repo}`;

// Empty in dev, `/PalForge` on GitHub Pages. Anything that builds a URL by hand (the
// search index fetch, the root redirect) has to prepend it.
export const basePath = process.env.NEXT_PUBLIC_BASE_PATH ?? '';
