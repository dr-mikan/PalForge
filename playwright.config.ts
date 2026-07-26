import { defineConfig, devices } from '@playwright/test';

// The docs site is a static export. `npm run serve` in docs/ serves the built out/
// directory, so the tests exercise exactly the files GitHub Pages will publish.
export default defineConfig({
  testDir: './e2e',
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 2 : 0,
  workers: process.env.CI ? 1 : undefined,
  reporter: process.env.CI ? [['html'], ['list']] : 'list',
  use: {
    baseURL: 'http://127.0.0.1:4321',
    trace: 'on-first-retry',
  },
  projects: [
    { name: 'chromium', use: { ...devices['Desktop Chrome'] } },
    { name: 'mobile', use: { ...devices['Pixel 5'] } },
  ],
  webServer: {
    command: 'npm --prefix docs run serve',
    url: 'http://127.0.0.1:4321/en/',
    reuseExistingServer: !process.env.CI,
    timeout: 120_000,
    stdout: 'pipe',
  },
});
