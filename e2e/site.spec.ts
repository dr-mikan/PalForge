import { expect, test } from '@playwright/test';
import { DOC_SLUGS, LOCALES, docUrl } from './pages';

test.describe('entry points', () => {
  test('the root document points at the default locale', async ({ page }) => {
    const response = await page.goto('/');
    expect(response?.ok()).toBeTruthy();
    // `output: export` cannot emit a server redirect, so the root is a static bounce page.
    await page.waitForURL(/\/en\/?$/, { timeout: 15_000 });
    await expect(page.getByRole('heading', { level: 1, name: 'PalForge' })).toBeVisible();
  });

  for (const locale of LOCALES) {
    test(`the ${locale} landing page renders`, async ({ page }) => {
      await page.goto(`/${locale}/`);
      await expect(page.getByRole('heading', { level: 1, name: 'PalForge' })).toBeVisible();
      await expect(page.getByRole('link', { name: /GitHub/i }).first()).toBeVisible();
    });

    test(`the ${locale} landing page links into the docs`, async ({ page }) => {
      await page.goto(`/${locale}/`);
      await page.locator(`a[href^="/${locale}/docs"]`).first().click();
      await page.waitForURL(new RegExp(`/${locale}/docs`));
      await expect(page.locator('article h1').first()).toBeVisible();
    });
  }
});

test.describe('every documented page', () => {
  for (const locale of LOCALES) {
    for (const slug of DOC_SLUGS) {
      const url = docUrl(locale, slug);

      test(`${url} renders with a title and body`, async ({ page }) => {
        const errors: string[] = [];
        page.on('console', (msg) => {
          if (msg.type() === 'error') errors.push(msg.text());
        });
        page.on('pageerror', (err) => errors.push(err.message));

        const response = await page.goto(url);
        expect(response?.status(), `${url} should be served`).toBeLessThan(400);

        const h1 = page.locator('article h1').first();
        await expect(h1).toBeVisible();
        await expect(h1).not.toBeEmpty();

        // A page that only has a title is a stub; every page here carries real prose.
        const bodyText = await page.locator('article').innerText();
        expect(bodyText.length, `${url} should have substantial content`).toBeGreaterThan(600);

        // The scaffolding stubs must never reach the published site. Match whole lines so
        // prose that legitimately describes a placeholder in the Lua source still passes.
        expect(bodyText).not.toMatch(/^\s*(Placeholder\.|プレースホルダー。|Lorem ipsum)\s*$/m);

        expect(errors, `${url} logged console errors`).toEqual([]);
      });
    }
  }
});

test.describe('navigation', () => {
  test('the sidebar lists every section', async ({ page }, testInfo) => {
    // On a phone the sidebar starts collapsed behind the menu button, which is the
    // intended layout — open it first so both viewports assert the same thing.
    await page.goto(docUrl('en', ''));
    if (testInfo.project.name === 'mobile') {
      await page.getByRole('button', { name: /menu|sidebar|toggle/i }).first().click();
    }
    for (const label of ['Concepts', 'API reference', 'Guides']) {
      await expect(page.getByText(label, { exact: true }).first()).toBeVisible();
    }
  });

  test('no internal link in the docs is broken', async ({ page, request }) => {
    const seen = new Set<string>();

    for (const slug of DOC_SLUGS) {
      await page.goto(docUrl('en', slug));
      const hrefs = await page.locator('article a[href^="/"]').evaluateAll((nodes) =>
        nodes.map((n) => (n as HTMLAnchorElement).getAttribute('href') ?? ''),
      );
      for (const href of hrefs) if (href) seen.add(href.split('#')[0]);
    }

    const broken: string[] = [];
    for (const href of seen) {
      if (!href) continue;
      const res = await request.get(href);
      if (res.status() >= 400) broken.push(`${href} -> ${res.status()}`);
    }
    expect(broken, 'these links 404').toEqual([]);
  });

  test('the language switch reaches the Japanese page', async ({ page }) => {
    await page.goto(docUrl('en', 'api/pal'));
    await page.goto(docUrl('ja', 'api/pal'));
    await expect(page.locator('html')).toHaveAttribute('lang', 'ja');
    const bodyText = await page.locator('article').innerText();
    // Japanese pages must actually be translated, not an English copy.
    expect(bodyText).toMatch(/[぀-ヿ一-龯]/);
  });
});

test.describe('layout', () => {
  for (const slug of DOC_SLUGS) {
    test(`${docUrl('en', slug)} does not scroll sideways`, async ({ page }) => {
      await page.goto(docUrl('en', slug));
      await page.waitForTimeout(500);
      // Wide content (tables, diagrams, long code) must scroll inside its own container,
      // never push the document itself sideways — that is what breaks reading on a phone.
      const overflow = await page.evaluate(() => {
        const el = document.documentElement;
        return el.scrollWidth - el.clientWidth;
      });
      expect(overflow, 'the page body overflows horizontally').toBeLessThanOrEqual(1);
    });
  }
});

test.describe('mermaid', () => {
  test('the lifecycle diagrams render to SVG', async ({ page }) => {
    await page.goto(docUrl('en', 'concepts/lifecycle'));

    const diagrams = page.locator('[data-mermaid]');
    await expect(diagrams.first()).toBeVisible();
    const count = await diagrams.count();
    expect(count, 'the lifecycle page should carry several diagrams').toBeGreaterThan(2);

    for (let i = 0; i < count; i += 1) {
      await expect(diagrams.nth(i).locator('svg')).toBeVisible({ timeout: 20_000 });
    }
    await expect(page.locator('.fd-mermaid-error')).toHaveCount(0);
  });

  test('no mermaid block fails to parse anywhere on the site', async ({ page }) => {
    const failures: string[] = [];

    for (const slug of DOC_SLUGS) {
      const url = docUrl('en', slug);
      await page.goto(url);
      const diagrams = page.locator('[data-mermaid]');
      const count = await diagrams.count();
      for (let i = 0; i < count; i += 1) {
        await expect(diagrams.nth(i).locator('svg')).toBeVisible({ timeout: 20_000 });
      }
      if ((await page.locator('.fd-mermaid-error').count()) > 0) failures.push(url);
    }

    expect(failures, 'these pages have an unparseable diagram').toEqual([]);
  });
});

test.describe('search', () => {
  test('the static index is published and covers both locales', async ({ request }) => {
    const res = await request.get('/api/search');
    expect(res.status()).toBe(200);
    const data = await res.json();
    expect(data.type).toBe('i18n');
    expect(Object.keys(data.data).sort()).toEqual(['en', 'ja']);
  });

  test('searching the English index finds the Pal reference', async ({ page }) => {
    await page.goto(docUrl('en', ''));
    await page.getByRole('button', { name: /search/i }).first().click();

    const dialog = page.getByRole('dialog');
    await dialog.getByPlaceholder(/search/i).fill('spawn');

    // Results render as command-menu items, not anchors.
    await expect(dialog).toContainText('Pal', { timeout: 15_000 });
    await expect(dialog).toContainText('spawn');
  });

  test('the Japanese index is searched when the locale is Japanese', async ({ page }) => {
    await page.goto(docUrl('ja', ''));
    await page.getByRole('button', { name: /検索|search/i }).first().click();

    const dialog = page.getByRole('dialog');
    await dialog.getByPlaceholder(/検索|search/i).fill('spawn');

    await expect(dialog).toContainText('Pal', { timeout: 15_000 });
    // A hit from the Japanese index carries Japanese prose with it.
    await expect(dialog).toContainText(/[぀-ヿ一-龯]/, { timeout: 15_000 });
  });
});
