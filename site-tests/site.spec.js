const { test, expect } = require('@playwright/test');
const AxeBuilder = require('@axe-core/playwright').default;

test('classifies samples locally, handles edits, and meets WCAG AA', async ({ page }) => {
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  await page.goto('/');
  await expect(page.locator('#rep')).toContainText('compilation Error');
  for (const [sample, category] of [['test', 'test Failure'], ['oom', 'resource Exhaustion'], ['sim', 'infra Failure']]) {
    await page.locator(`[data-s=${sample}]`).click();
    await expect(page.locator('#rep')).toContainText(category);
  }
  const editRequests = [];
  page.on('request', request => editRequests.push(request.url()));
  await page.locator('#log').fill('error: <img src=x onerror=alert(1)> unknown failure\n** BUILD FAILED **');
  await expect(page.locator('#rep')).toContainText('unknown');
  await expect(page.locator('#rep img')).toHaveCount(0);
  expect(editRequests).toEqual([]);
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBeTruthy();
  await page.keyboard.press('Tab');
  const audit = await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa', 'wcag21aa']).analyze();
  expect(audit.violations).toEqual([]);
  expect(errors).toEqual([]);
});

test('shows a useful fallback and disables controls when rules fail', async ({ page }) => {
  await page.route('**/rules.json', route => route.fulfill({ status: 503, body: 'unavailable' }));
  await page.goto('/');
  await expect(page.locator('#boot')).toContainText('could not load');
  await expect(page.locator('#log')).toBeDisabled();
  for (const button of await page.locator('[data-s]').all()) await expect(button).toBeDisabled();
  await expect(page.locator('#install')).toContainText('swift build -c release');
});

test('works as an install guide without JavaScript', async ({ browser }) => {
  const context = await browser.newContext({ javaScriptEnabled: false });
  const page = await context.newPage();
  await page.goto('http://127.0.0.1:4197/');
  await expect(page.locator('noscript p')).toContainText('JavaScript');
  await expect(page.locator('#log')).toBeDisabled();
  await expect(page.locator('#install')).toBeVisible();
  await context.close();
});

test('respects reduced motion and keyboard navigation', async ({ page, browserName }) => {
  await page.emulateMedia({ reducedMotion: 'reduce' });
  await page.goto('/');
  if (browserName === 'webkit') await page.locator('.skip').focus();
  else await page.keyboard.press('Tab');
  await expect(page.locator('.skip')).toBeFocused();
  await page.keyboard.press('Enter');
  expect(await page.evaluate(() => location.hash)).toBe('#try');
  expect(await page.locator('.btn').first().evaluate(el => getComputedStyle(el).transitionDuration)).toBe('0s');
});
