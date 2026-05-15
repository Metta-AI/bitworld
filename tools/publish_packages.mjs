#!/usr/bin/env npx playwright test --config /dev/null
/**
 * Makes all ghcr.io/malcolmocean/bitworld-* packages public.
 * Usage: npx playwright test tools/publish_packages.mjs
 *    or: node tools/publish_packages.mjs (with GITHUB_USER env var optional)
 *
 * The script opens a browser, lets you log into GitHub, then iterates
 * through each package's settings page and changes visibility to public.
 */
import { chromium } from 'playwright';

const GITHUB_USER = process.env.GITHUB_USER || 'malcolmocean';

const PACKAGES = [
  'bitworld-stag-hunt',
  'bitworld-stag-hunt-coordinator',
  'bitworld-stag-hunt-nearest-hunter',
  'bitworld-stag-hunt-rabbiteer',
  'bitworld-stag-hunt-sidekick',
  'bitworld-stag-hunt-stag-hunter',
];

async function main() {
  const browser = await chromium.launch({ headless: false });
  const context = await browser.newContext();
  const page = await context.newPage();

  // Let user log in
  await page.goto('https://github.com/login');
  console.log('Please log into GitHub in the browser window...');
  await page.waitForURL('https://github.com/**', { timeout: 120_000 });
  console.log('Logged in.');

  for (const pkg of PACKAGES) {
    const settingsUrl = `https://github.com/users/${GITHUB_USER}/packages/container/${pkg}/settings`;
    console.log(`\nProcessing: ${pkg}`);
    await page.goto(settingsUrl);

    // Click "Change visibility" button in the danger zone
    const changeBtn = page.getByRole('button', { name: /Change visibility/i });
    await changeBtn.waitFor({ timeout: 10_000 });
    await changeBtn.click();

    // Select "Public" radio in the modal/dialog
    const publicRadio = page.getByLabel(/Public/i).first();
    await publicRadio.waitFor({ timeout: 5_000 });
    await publicRadio.click();

    // Type the package name to confirm
    const confirmInput = page.getByPlaceholder(/package name/i).or(
      page.locator('input[name="verify"]')
    ).or(
      page.locator('input[aria-label*="verify"]')
    );
    await confirmInput.waitFor({ timeout: 5_000 });
    await confirmInput.fill(pkg);

    // Click the final confirm button
    const confirmBtn = page.getByRole('button', { name: /I understand/i }).or(
      page.getByRole('button', { name: /make this package public/i })
    );
    await confirmBtn.click();

    // Wait for navigation back to settings
    await page.waitForTimeout(2_000);
    console.log(`  ✓ ${pkg} is now public`);
  }

  console.log('\nAll packages are public!');
  await browser.close();
}

main().catch(err => {
  console.error(err);
  process.exit(1);
});
