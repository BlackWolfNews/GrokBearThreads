import assert from 'node:assert/strict';
import test from 'node:test';
import { bridgeRequest, redirectRule } from '../../Sources/Threadbear/Resources/ChromeSignIn/bridge.mjs';

const nonce = 'a'.repeat(64);
const state = '/d/quick-fox?threadbear_sign_in=' + nonce;
const login = new URL('https://dashboard.convex.dev/api/auth/login');
login.searchParams.set('returnTo', state);
const start = new URL(`http://127.0.0.1:54321/start/${nonce}`);
start.hash = new URLSearchParams({ login: login.href }).toString();

test('only an explicit click on the app handshake can start sign-in', () => {
  const bridge = bridgeRequest(start.href);
  assert.equal(bridge.loginURL, login.href);
  assert.equal(bridge.callbackURL, `http://127.0.0.1:54321/finish/${nonce}`);
  for (const address of [
    start.href.replace('127.0.0.1', 'evil.test'),
    start.href.replace('http:', 'https:'),
    start.href.replace('54321', '80'),
    start.href.replace('/start/', '/other/'),
    start.href.replace(nonce, 'wrong'),
    start.href.replace('dashboard.convex.dev', 'evil.test'),
    start.href.replace('api%2Fauth%2Flogin', 'api%2Fauth%2Flogout'),
  ]) assert.throws(() => bridgeRequest(address), address);
});

test('a redirect is confined to this one tab and the exact HTTPS callback', () => {
  const rule = redirectRule(42, bridgeRequest(start.href));
  assert.deepEqual(rule.condition.tabIds, [42]);
  assert.deepEqual(rule.condition.resourceTypes, ['main_frame']);
  const pattern = new RegExp(rule.condition.regexFilter);
  const callback = 'https://dashboard.convex.dev/api/auth/callback?code=fake-code&state=' + encodeURIComponent(state);
  assert.match(callback, pattern);
  assert.equal(callback.replace(pattern, rule.action.redirect.regexSubstitution.replace('\\1', '$1')),
    `http://127.0.0.1:54321/finish/${nonce}?code=fake-code&state=${encodeURIComponent(state)}`);
  for (const address of [callback.replace('https:', 'http:'), callback.replace('.dev/', '.dev.evil.test/'), callback.replace('/callback?', '/callback/evil?')]) {
    assert.doesNotMatch(address, pattern);
  }
  assert.throws(() => redirectRule(-1, bridgeRequest(start.href)));
});
