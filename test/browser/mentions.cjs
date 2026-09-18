// Run against an isolated instance with agents disabled and manager/maintainer seeded.
// PLAYWRIGHT_MODULE may point at an existing Playwright installation.
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const assert = require('node:assert/strict');

(async () => {
  const browser = await chromium.launch({headless: true, executablePath: process.env.CHROMIUM || '/usr/bin/chromium', args: ['--no-sandbox']});
  try {
    const page = await browser.newPage({viewport: {width: 1440, height: 1000}});
    const errors = [];
    page.on('pageerror', error => errors.push(error.message));
    await page.goto(process.env.ROUNDTABLE_TEST_URL || 'http://127.0.0.1:4437');
    await page.waitForFunction(() => window.liveSocket?.isConnected());
    const input = page.locator('#message-body');
    const menu = page.locator('#mention-menu');

    await input.fill('@mana');
    await page.waitForFunction(() => {
      const menu = document.querySelector('#mention-menu');
      return !menu.hidden && menu.textContent === '@manager' && !document.querySelector('.phx-change-loading');
    });
    // Visibility checks alone don't catch a menu clipped by its parent.
    assert(await menu.locator('li').evaluate(el => {
      const rect = el.getBoundingClientRect();
      return el.contains(document.elementFromPoint(rect.x + rect.width / 2, rect.y + rect.height / 2));
    }), 'the menu must be visible and hit-testable above the composer');
    await input.press('Tab');
    assert.equal(await input.inputValue(), '@manager ');
    assert(await menu.isHidden());
    assert.equal(await page.locator('.message').count(), 0, 'completion must not send a message');

    await input.fill('@ma');
    await menu.locator('li').first().waitFor({state: 'visible'});
    const names = await menu.locator('li').allTextContents();
    assert.equal(names.length, 2);
    await input.press('ArrowDown');
    await input.press('Enter');
    assert.equal(await input.inputValue(), names[1] + ' ');

    await input.fill('Please @mana');
    await menu.getByRole('option', {name: '@manager', exact: true}).click();
    assert.equal(await input.inputValue(), 'Please @manager ');

    await input.fill('@manager later');
    await input.evaluate(el => { el.setSelectionRange(5, 5); el.dispatchEvent(new Event('click')); });
    await input.press('Tab');
    assert.equal(await input.inputValue(), '@manager  later', 'completion replaces the whole existing mention');

    await input.fill('@zzzz');
    assert(await menu.isHidden());
    await input.fill('person@mana');
    assert(await menu.isHidden(), 'email text is not a mention');
    await input.fill('@ma');
    await input.press('Escape');
    assert(await menu.isHidden());
    await input.fill('@mana');
    await input.press('Shift+Enter');
    assert.equal(await input.inputValue(), '@mana\n');
    assert.equal(await page.locator('.message').count(), 0);

    await page.setViewportSize({width: 390, height: 844});
    await input.fill('@mana');
    await menu.locator('li').first().waitFor({state: 'visible'});
    assert(await menu.locator('li').evaluate(el => {
      const r = el.getBoundingClientRect();
      return el.contains(document.elementFromPoint(r.x + 10, r.y + r.height / 2));
    }), 'mobile menu must also be clickable');
    await input.fill('');
    assert.deepEqual(errors, []);
    console.log('Mention browser checks passed: visible menu, LiveView patches, filtering, Tab/Enter/arrows/click, Escape, multiline, caret replacement, mobile; no messages sent.');
  } finally {
    await browser.close();
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
