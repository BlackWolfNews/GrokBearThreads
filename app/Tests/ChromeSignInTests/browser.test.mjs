// Optional browser integration check. Uses a fresh profile, synthetic
// auth responses and a loopback server. Never opens a real login.
// PLAYWRIGHT_MODULE=/path/to/playwright/index.mjs node --test app/Tests/ChromeSignInTests/browser.test.mjs
import assert from 'node:assert/strict';
import { appendFile, cp, mkdtemp, rm } from 'node:fs/promises';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

test('Chrome redirects the fresh callback before Convex consumes it and removes the rule on tab close', { timeout: 15000 }, async (t) => {
  const { chromium } = await import(process.env.PLAYWRIGHT_MODULE || 'playwright');
  const profile = await mkdtemp(path.join(os.tmpdir(), 'threadbear-chrome-test-'));
  const source = fileURLToPath(new URL('../../Sources/Threadbear/Resources/ChromeSignIn', import.meta.url));
  const extension = path.join(profile, 'extension');
  await cp(source, extension, { recursive: true });
  // Only the disposable test copy exposes the toolbar handler to CDP.
  await appendFile(path.join(extension, 'worker.mjs'), '\nglobalThis.startForTest = startSignIn;\n');
  const nonce = 'b'.repeat(64);
  const state = '/d/fake-deployment?threadbear_sign_in=' + nonce;
  let returnRequest;
  const server = http.createServer((request, response) => {
    response.writeHead(200, { 'Content-Type': 'text/html' });
    response.end('<title>Threadbear sign-in test</title>');
    if (request.url.startsWith('/finish/')) returnRequest = request.url;
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  let browser;
  let stage = 'launch';
  const abort = () => {
    console.error('Timed out at', stage);
    void browser?.close();
    server.closeAllConnections();
    server.close();
  };
  t.signal.addEventListener('abort', abort);
  try {
    browser = await chromium.launchPersistentContext(path.join(profile, 'profile'), {
      headless: true, channel: 'chromium',
      args: [`--disable-extensions-except=${extension}`, `--load-extension=${extension}`],
    });
    stage = 'route setup';
    let callbackHitServer = false;
    await browser.route('https://dashboard.convex.dev/**', async (route) => {
      const url = new URL(route.request().url());
      if (url.pathname === '/api/auth/login') {
        const callback = new URL('https://dashboard.convex.dev/api/auth/callback');
        callback.search = new URLSearchParams({ code: 'fake-once-only-code', state }).toString();
        await route.fulfill({ status: 302, headers: { location: callback.href } });
      } else {
        callbackHitServer = true;
        await route.fulfill({ status: 200, body: 'Callback already consumed' });
      }
    });
    stage = 'worker';
    const worker = browser.serviceWorkers()[0] || await browser.waitForEvent('serviceworker');
    const tab = await browser.newPage();
    const login = new URL('https://dashboard.convex.dev/api/auth/login');
    login.search = new URLSearchParams({ returnTo: state }).toString();
    const start = new URL(`http://127.0.0.1:${server.address().port}/start/${nonce}`);
    start.hash = new URLSearchParams({ login: login.href }).toString();
    stage = 'start page';
    await tab.goto(start.href);
    stage = 'toolbar handler';
    const tabId = await worker.evaluate(async (url) => {
      const [tab] = await chrome.tabs.query({ active: true, lastFocusedWindow: true });
      // This calls the same handler as the toolbar click. Supplying the
      // known start URL stands in for activeTab's user-gesture grant.
      await globalThis.startForTest({ id: tab.id, url });
      return tab.id;
    }, start.href);
    stage = 'callback';
    await tab.waitForURL(`${start.origin}/finish/${nonce}?**`, { timeout: 5000, waitUntil: 'load' });
    assert.ok(returnRequest, 'The loopback server must receive the callback');
    const result = new URL(returnRequest, start.origin);
    assert.equal(result.pathname, '/finish/' + nonce);
    assert.equal(result.searchParams.get('code'), 'fake-once-only-code');
    assert.equal(result.searchParams.get('state'), state);
    assert.equal(callbackHitServer, false, 'Convex must receive the fresh code only from the waiting web view');
    const unrelated = await browser.newPage();
    await unrelated.goto('https://dashboard.convex.dev/api/auth/callback?code=another-fake-code&state=unrelated');
    assert.equal(callbackHitServer, true, 'A callback in another tab must reach its original destination');
    await unrelated.close();
    stage = 'close tab';
    await tab.close();
    stage = 'remove rule';
    let rules = [];
    for (let attempt = 0; attempt < 20; attempt++) {
      rules = await worker.evaluate(() => chrome.declarativeNetRequest.getSessionRules());
      if (!rules.some((rule) => rule.id === tabId)) break;
      await new Promise((resolve) => setTimeout(resolve, 20));
    }
    assert.ok(!rules.some((rule) => rule.id === tabId));
  } finally {
    t.signal.removeEventListener('abort', abort);
    stage = 'cleanup';
    await browser?.close();
    server.closeAllConnections();
    await new Promise((resolve) => server.close(resolve));
    await rm(profile, { recursive: true, force: true });
  }
});
