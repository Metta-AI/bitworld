/**
 * Makes all ghcr.io container packages public for a GitHub user.
 *
 * Uses dev-browser (must be installed: npm install -g dev-browser && dev-browser install).
 * The user must log in interactively in the browser window that opens.
 *
 * Usage:
 *   node tools/publish_packages.mjs
 *   GITHUB_USER=someone node tools/publish_packages.mjs
 */

import { execSync } from 'child_process';

const GITHUB_USER = process.env.GITHUB_USER || 'malcolmocean';
const PAGE_NAME = 'github-publish';

const PACKAGES = [
  'bitworld-stag-hunt',
  'bitworld-stag-hunt-coordinator',
  'bitworld-stag-hunt-nearest-hunter',
  'bitworld-stag-hunt-rabbiteer',
  'bitworld-stag-hunt-sidekick',
  'bitworld-stag-hunt-stag-hunter',
];

function run(script) {
  return execSync(`dev-browser <<'DEVEOF'\n${script}\nDEVEOF`, {
    encoding: 'utf-8',
    shell: '/bin/zsh',
    timeout: 30000,
  }).trim();
}

// Step 1: open login page
console.log('Opening GitHub login page...');
run(`
  const page = await browser.getPage("${PAGE_NAME}");
  await page.goto("https://github.com/login", { waitUntil: "domcontentloaded" });
  console.log(JSON.stringify({ url: page.url() }));
`);

// Step 2: wait for login
console.log('Please log into GitHub in the browser window.');
console.log('Press Enter here once you are logged in...');
await new Promise(resolve => {
  process.stdin.once('data', resolve);
});

// Step 3: iterate packages
for (const pkg of PACKAGES) {
  const settingsUrl = `https://github.com/users/${GITHUB_USER}/packages/container/${pkg}/settings`;
  console.log(`\nProcessing: ${pkg}`);

  const status = run(`
    const page = await browser.getPage("${PAGE_NAME}");
    await page.goto("${settingsUrl}", { waitUntil: "domcontentloaded" });
    await page.waitForSelector("button");
    const snap = await page.snapshotForAI();
    const isPublic = snap.full.includes("currently public");
    console.log(JSON.stringify({ isPublic }));
  `);

  const { isPublic } = JSON.parse(status);
  if (isPublic) {
    console.log(`  Already public, skipping.`);
    continue;
  }

  run(`
    const page = await browser.getPage("${PAGE_NAME}");
    const btn = page.getByRole("button", { name: "Change visibility" });
    await btn.click();
    await page.waitForTimeout(1000);
    const publicRadio = page.getByRole("radio", { name: /Public/i });
    await publicRadio.click();
    const input = page.getByRole("textbox", { name: /Please type/i });
    await input.fill("${pkg}");
    const confirm = page.getByRole("button", { name: /I understand the consequences/i });
    await confirm.click();
    await page.waitForTimeout(3000);
  `);

  console.log(`  Made public.`);
}

console.log('\nDone!');
run(`
  const page = await browser.getPage("${PAGE_NAME}");
  await page.close();
`);
