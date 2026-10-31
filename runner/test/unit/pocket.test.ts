// The `pocket` tool (threadbear-mcp.ts): one tool that files, replaces,
// removes and lists the cards on the phone.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { makeHarness } from '../helpers/fakes.ts';
import { buildThreadbearTools, type PocketControl } from '../../src/threadbear-mcp.ts';

function setup() {
  const saved: Parameters<PocketControl['savePocketCard']>[0][] = [];
  const removed: string[] = [];
  const pocket: PocketControl = {
    savePocketCard: async (card) => {
      saved.push(card);
      return saved.length > 1 ? 'replaced' : 'added';
    },
    removePocketCard: async (title) => {
      removed.push(title);
      return title === 'There';
    },
    pocketCards: async () => [{ title: 'There', text: 'Line one', place: 'post office', source: 'misc', updatedAt: 'now' }],
  };
  return { saved, removed, pocket };
}

async function call(tools: ReturnType<typeof buildThreadbearTools>, args: Record<string, unknown>) {
  const r = (await tools.find((t) => t.name === 'pocket')!.handler(args as never, {})) as { content: { text: string }[]; isError?: boolean };
  return { text: r.content[0]!.text, isError: r.isError };
}

test('files a card with the thread it came from, and the same title replaces it', async () => {
  const h = makeHarness();
  const { thread } = await h.runner.create({ text: 'Passport' } as never);
  const { saved, pocket } = setup();
  const tools = buildThreadbearTools(h.runner, thread.id, Date.now, undefined, undefined, undefined, { pocket: () => pocket });
  assert.match((await call(tools, { title: 'Post to Corby', text: 'Long Croft Road', place: 'post office' })).text, /Filed/);
  assert.match((await call(tools, { title: 'Post to Corby', text: 'New' })).text, /Replaced/);
  assert.equal(saved[0]!.threadId, thread.id);
  assert.equal(saved[0]!.place, 'post office');
  // The folder, not the thread's title, which starts as the first message.
  assert.equal(saved[0]!.source, path.basename(thread.cwd));
  assert.equal(saved[1]!.place, undefined);
});

test('removes by title, and says when there was no such card', async () => {
  const h = makeHarness();
  const { thread } = await h.runner.create({ text: 'hi' } as never);
  const { removed, saved, pocket } = setup();
  const tools = buildThreadbearTools(h.runner, thread.id, Date.now, undefined, undefined, undefined, { pocket: () => pocket });
  assert.match((await call(tools, { title: 'There', remove: true })).text, /Took "There" out/);
  assert.match((await call(tools, { title: 'Nope', remove: true })).text, /No card called/);
  assert.deepEqual(removed, ['There', 'Nope']);
  assert.equal(saved.length, 0);
});

test('no title lists the cards; a title with no text is an error', async () => {
  const h = makeHarness();
  const { thread } = await h.runner.create({ text: 'hi' } as never);
  const { pocket } = setup();
  const tools = buildThreadbearTools(h.runner, thread.id, Date.now, undefined, undefined, undefined, { pocket: () => pocket });
  assert.match((await call(tools, {})).text, /There \(post office\) \[misc\]\nLine one/);
  const bad = await call(tools, { title: 'There' });
  assert.equal(bad.isError, true);
});

test('no tool at all while sync is off', async () => {
  const h = makeHarness();
  const { thread } = await h.runner.create({ text: 'hi' } as never);
  const tools = buildThreadbearTools(h.runner, thread.id, Date.now, undefined, undefined, undefined, { pocket: () => undefined });
  assert.equal(tools.find((t) => t.name === 'pocket'), undefined);
});
