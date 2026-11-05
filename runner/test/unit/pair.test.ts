import { test } from 'node:test';
import assert from 'node:assert/strict';
import { pairText } from '../../src/pair.ts';

// tb pair: the other Mac's app takes the host only from here (RunnerHostPin
// in the app), so what it prints has to carry the .host line.
test('tb pair prints the token file and the .host line, not the token', () => {
  const home = '/Users/bruce/Library/Application Support/Threadbear';
  const r = pairText({ home, sync: { enabled: true, name: 'bruce', runnerId: 'cb921b2447ea', rpcUrl: 'wss://Bruce.tail9ef766.ts.net.:8798/rpc' } }, 'bruce');
  assert.equal(r.ok, true);
  assert.match(r.text, /cb921b2447ea\.host {3}this one line: bruce\.tail9ef766\.ts\.net$/m, 'host only, lowercased, no trailing dot');
  assert.match(r.text, /cb921b2447ea\.token {2}a copy of \/Users\/bruce\/Library\/Application Support\/Threadbear\/secrets\/runner-token/);
  assert.match(r.text, /printf '%s\\n' bruce\.tail9ef766\.ts\.net > "\$d\/cb921b2447ea\.host"/);
  assert.match(r.text, /scp 'bruce@bruce\.tail9ef766\.ts\.net:\/Users\/bruce\/Library\/Application Support\/Threadbear\/secrets\/runner-token'/);
});

test('tb pair says what is missing without an id or an rpcUrl', () => {
  const noId = pairText({ home: '/h', sync: { enabled: true, rpcUrl: 'wss://a.ts.net/rpc' } }, 'u');
  assert.equal(noId.ok, false);
  assert.match(noId.text, /sync\.runnerId/);
  const noUrl = pairText({ home: '/h', sync: { enabled: true, runnerId: 'abc' } }, 'u');
  assert.equal(noUrl.ok, false);
  assert.match(noUrl.text, /sync\.rpcUrl/);
  assert.equal(pairText({ home: '/h', sync: { enabled: true, runnerId: 'abc', rpcUrl: 'not a url' } }, 'u').ok, false);
});
