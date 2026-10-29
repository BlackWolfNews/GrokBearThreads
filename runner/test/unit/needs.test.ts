import { test } from 'node:test';
import assert from 'node:assert/strict';
import type { PersistedEvent } from '../../src/protocol.ts';
import { archiveFromTool, CODEX_END_TURN_DESCRIPTION, END_TURN_DESCRIPTION, END_TURN_FULL_NAME, needsFromText, needsFromTool, summaryFromTool, summaryMarkdown, turnReply } from '../../src/needs.ts';
import { END_TURN_TOOL } from '../../src/needs.ts';
import { SERVER_NAME } from '../../src/threadbear-mcp.ts';
import { ClaudeNormalizer, fileContext } from '../../src/adapters/claude/normalize.ts';

test('end_turn input: nothing, you with asks, and junk falls back', () => {
  assert.deepEqual(needsFromTool({ needs: 'nothing', asks: [{ action: 'ignored' }] }), { needs: 'nothing' });
  assert.deepEqual(
    needsFromTool({ needs: 'you', asks: [{ action: ' Paste the key ', where: 'Settings › Models', reply: 'done' }, { action: '' }, 'x', { action: 'Pick a budget', where: '' }] }),
    { needs: 'you', asks: [{ action: 'Paste the key', where: 'Settings › Models', reply: 'done' }, { action: 'Pick a budget' }] },
  );
  assert.deepEqual(needsFromTool({ needs: 'you' }), { needs: 'you' });
  assert.equal(needsFromTool({ needs: 'maybe' }), undefined);
  // archive only counts with needs "nothing": a thread that asks for something stays in the inbox.
  assert.equal(archiveFromTool({ needs: 'nothing', archive: true }), true);
  assert.equal(archiveFromTool({ needs: 'you', archive: true }), false);
  assert.equal(archiveFromTool({ needs: 'nothing', archive: 'yes' }), false);
  assert.equal(archiveFromTool({ needs: 'nothing' }), false);
  assert.equal(archiveFromTool(undefined), false);
  assert.equal(needsFromTool(null), undefined);
  assert.equal(needsFromTool({ needs: 'you', asks: Array.from({ length: 20 }, (_, i) => ({ action: `a${i}` })) })!.asks!.length, 10);
});

test('end_turn input: needs left out comes from the asks', () => {
  // Agents filling in a summary forgot needs 2 times in 9 (29 Oct 2026).
  assert.deepEqual(needsFromTool({ asks: [{ action: 'Paste the key', why: 'For the deploy.' }] }), { needs: 'you', asks: [{ action: 'Paste the key', why: 'For the deploy.' }] });
  assert.deepEqual(needsFromTool({ summary: ['Fixed it.'] }), { needs: 'nothing' });
  assert.deepEqual(needsFromTool({ asks: [{ action: '' }] }), { needs: 'nothing' });
  assert.deepEqual(needsFromTool({}), { needs: 'nothing' });
  assert.equal(archiveFromTool({ archive: true }), true);
  assert.equal(archiveFromTool({ archive: true, asks: [{ action: 'Look' }] }), false);
});

test('end_turn summary: bullets kept tidy, a few at most, none is undefined', () => {
  assert.deepEqual(summaryFromTool({ summary: ['- Fixed the slug bug.', ' • [Tests pass](work:npm test) ', '', 3, '* Committed as `b08255b`.'] }), ['Fixed the slug bug.', '[Tests pass](work:npm test)', 'Committed as `b08255b`.']);
  assert.equal(summaryFromTool({ summary: [] }), undefined);
  assert.equal(summaryFromTool({ summary: 'Fixed it.' }), undefined);
  assert.equal(summaryFromTool({ needs: 'nothing' }), undefined);
  assert.equal(summaryFromTool({ summary: Array.from({ length: 12 }, (_, i) => `b${i}`) })!.length, 8);
  assert.equal(summaryFromTool({ summary: ['x'.repeat(600)] })![0].length, 400);
  assert.equal(summaryMarkdown(['One.', 'Two.']), '- One.\n- Two.');
});

test("end_turn's description asks for a short summary with links into the thread", () => {
  for (const d of [END_TURN_DESCRIPTION, CODEX_END_TURN_DESCRIPTION]) {
    assert.match(d, /summary/);
    assert.match(d, /work:/);
    assert.match(d, /thread:/);
  }
});

test('end_turn input: a decision keeps its why, options and a valid pick', () => {
  assert.deepEqual(
    needsFromTool({ needs: 'you', asks: [{ action: 'Merge #52?', why: ' Preview is green. ', options: ['Merge', ' ', 'Test locally', 3], suggested: 1 }] }),
    { needs: 'you', asks: [{ action: 'Merge #52?', why: 'Preview is green.', options: ['Merge', 'Test locally'], suggested: 1 }] },
  );
  // A pick that isn't one of the options is dropped, and so is one with no options.
  assert.deepEqual(needsFromTool({ needs: 'you', asks: [{ action: 'a', options: ['x'], suggested: 4 }] })!.asks, [{ action: 'a', options: ['x'] }]);
  assert.deepEqual(needsFromTool({ needs: 'you', asks: [{ action: 'a', options: [], suggested: 0 }] })!.asks, [{ action: 'a' }]);
  assert.equal(needsFromTool({ needs: 'you', asks: [{ action: 'a', options: Array.from({ length: 9 }, (_, i) => `o${i}`) }] })!.asks![0].options!.length, 6);
});

test('end_turn input: links to go and do the thing, web or local, a few at most', () => {
  const asks = needsFromTool({
    needs: 'you',
    asks: [{
      action: 'Log in to Hugging Face',
      links: [
        { title: ' Open login page ', url: 'https://huggingface.co/login' },
        { title: 'Notes', url: '~/dev/notes.md' },
        { title: 'Spec', url: '/Users/m/spec.md' },
        { title: 'Bad scheme', url: 'javascript:alert(1)' },
        { title: '', url: 'https://example.com' },
        { title: 'No url' },
        'junk',
        { title: 'Fourth good one', url: 'http://localhost:3000' },
      ],
    }],
  })!.asks!;
  assert.deepEqual(asks[0].links, [
    { title: 'Open login page', url: 'https://huggingface.co/login' },
    { title: 'Notes', url: '~/dev/notes.md' },
    { title: 'Spec', url: '/Users/m/spec.md' },
  ]);
  assert.equal(needsFromTool({ needs: 'you', asks: [{ action: 'a', links: [] }] })!.asks![0].links, undefined);
});

test('the section: a bold heading then a numbered list, with a reply phrase', () => {
  const text = [
    'The Settings window is in.',
    '',
    '**What I need from you**',
    '',
    '1. Open Settings > Models, paste your OpenRouter key, then reply "key set".',
    '   It only needs a small credit limit.',
    '',
    '2. Say whether **$1 a day** is right.',
    '',
    "Meanwhile I'll keep going on the app side.",
  ].join('\n');
  assert.deepEqual(needsFromText(text), {
    needs: 'you',
    asks: [
      { action: 'Open Settings > Models, paste your OpenRouter key, then reply "key set". It only needs a small credit limit.', reply: 'key set' },
      { action: 'Say whether $1 a day is right.' },
    ],
  });
});

test('the section: "nothing needed" under the heading, on its line, or with no heading', () => {
  assert.deepEqual(needsFromText('Done.\n\n**What I need from you**\n\nNothing needed from you right now. It is finished.'), { needs: 'nothing' });
  assert.deepEqual(needsFromText('Done.\n\n**What I need from you:** nothing right now. Still building.'), { needs: 'nothing' });
  assert.deepEqual(needsFromText('Done.\n\nNothing needed from you right now, the work is done. Next step: archive it.'), { needs: 'nothing' });
  assert.deepEqual(needsFromText('I wrote the file. The task is finished, and nothing is needed from you right now.'), { needs: 'nothing' });
});

test('the section: the last heading wins, a mention in a sentence does not count', () => {
  const text = [
    'Agents end with a **What I need from you** section, which we could parse.',
    '',
    '**What I need from you**',
    '',
    '- Reply "go" to build it.',
  ].join('\n');
  assert.deepEqual(needsFromText(text), { needs: 'you', asks: [{ action: 'Reply "go" to build it.', reply: 'go' }] });
  assert.equal(needsFromText('It reads the "What I need from you" heading. I will report back.'), undefined);
  assert.equal(needsFromText('All done here.'), undefined);
});

test('the section: a # heading, and prose under it with no list is one ask', () => {
  assert.deepEqual(needsFromText('## What I need from you\n\n1. Say yes or no.'), { needs: 'you', asks: [{ action: 'Say yes or no.' }] });
  assert.deepEqual(needsFromText('**What I need from you**\n\nRestart the app when you get a minute.'), { needs: 'you', asks: [{ action: 'Restart the app when you get a minute.' }] });
});

test('the section: choices under an ask stay with it, and a choice is not a reply', () => {
  const text = [
    '**What I need from you**',
    '',
    '1. Pick a fix and reply with it:',
    '   - "fix it": I make the tests work.',
    '   - "leave it": nothing changes.',
    '2. Decide on the filter. Reply "filter" or "wait".',
  ].join('\n');
  assert.deepEqual(needsFromText(text), {
    needs: 'you',
    asks: [
      { action: 'Pick a fix and reply with it: "fix it": I make the tests work. "leave it": nothing changes.' },
      { action: 'Decide on the filter. Reply "filter" or "wait".', options: ['filter', 'wait'] },
    ],
  });
});

// Fable skipped end_turn and wrote this; the card had one button (28 Oct 2026).
test('the section: every quoted answer in a list is a choice', () => {
  const ask = (line: string) => needsFromText(`**What I need from you**\n\n1. ${line}`)!.asks![0];
  assert.deepEqual(
    ask('Say whether to keep "Browser" or rename the row to "Website". Reply with "Land it", "Website, then land it", or what else to change.').options,
    ['Land it', 'Website, then land it'],
  );
  assert.deepEqual(ask('Reply "merge", "wait" or "close".').options, ['merge', 'wait', 'close']);
  assert.deepEqual(ask('Reply “yes” / “no”.').options, ['yes', 'no']);
  // A quote that isn't straight after the reply word isn't one of them.
  assert.deepEqual(ask('Reply "go" when the "Export" step is done.'), { action: 'Reply "go" when the "Export" step is done.', reply: 'go' });
});

test('the section: a code block in an ask stays in it', () => {
  const text = '**What I need from you**\n\n1. Run this:\n```\n- not an item\n```\nThen reply "done".';
  assert.deepEqual(needsFromText(text), { needs: 'you', asks: [{ action: 'Run this: ``` - not an item ``` Then reply "done".', reply: 'done' }] });
});

// ------------------------------------------------------------ turnReply

// Events as the thread's log has them, seq in order, with only the fields
// the check reads.
function log(...items: (Record<string, unknown> & { type: string })[]): PersistedEvent[] {
  return items.map((e, i) => ({ seq: i + 1, ts: '2026-10-28T06:10:00Z', threadId: 't', ...e }) as unknown as PersistedEvent);
}
const END = END_TURN_FULL_NAME;
const user = (text = 'hi') => ({ type: 'user.message', text, images: [] });
const started = { type: 'turn.started', turnId: 'turn-1' };
const text = (text: string, itemId = 'm1') => ({ type: 'assistant.text', itemId, text });
const thought = (itemId = 'r1') => ({ type: 'reasoning', itemId, text: 'Custom firmware would not help much.' });
const call = (itemId: string, name: string) => ({ type: 'tool.call', itemId, name, kind: 'mcp', title: name, input: {} });
const result = (itemId: string) => ({ type: 'tool.result', itemId, ok: true, text: '', truncated: false, images: [] });

test('turnReply: the full tool name is the one the server registers', () => {
  assert.equal(END, `mcp__${SERVER_NAME}__${END_TURN_TOOL}`);
});

test('turnReply: a message, then end_turn, is a reply; thinking and tool calls alone are not', () => {
  assert.deepEqual(turnReply(log(user(), started, thought(), text('No, the camera is not where the delay is.'), call('e1', END))), { landed: true, replied: true });
  // What happened on 28 Oct: the answer drafted in thinking, two commands, then end_turn.
  assert.deepEqual(turnReply(log(user(), started, thought(), call('b1', 'Bash'), result('b1'), call('b2', 'Bash'), result('b2'), thought('r2'), call('e1', END))), { landed: true, replied: false });
  // A progress line, then more work, then end_turn: the line isn't the answer.
  assert.deepEqual(turnReply(log(user(), started, text('Found it, checking one thing.'), call('s1', 'mcp__agent-archive__search_archive'), result('s1'), call('e1', END))), { landed: true, replied: false });
  // Nothing at all.
  assert.deepEqual(turnReply(log(user(), started, call('e1', END))), { landed: true, replied: false });
});

test("turnReply: the thread's own tools after the message don't count as work, nor does a refused end_turn", () => {
  const own = `mcp__${SERVER_NAME}__pin`;
  assert.deepEqual(turnReply(log(user(), started, text('Done, pinned.'), call('p1', own), result('p1'), call('e1', END))), { landed: true, replied: true });
  // Loading end_turn's deferred schema isn't work either (a Haiku thread was refused for it, 28 Oct).
  assert.deepEqual(turnReply(log(user(), started, text('Hello.'), call('ts', 'ToolSearch'), result('ts'), call('e1', END))), { landed: true, replied: true });
  // Refused once, the reply written, called again.
  assert.deepEqual(turnReply(log(user(), started, call('b1', 'Bash'), result('b1'), call('e1', END), result('e1'), text('All green.'), call('e2', END))), { landed: true, replied: true });
  // A tool still running (no result) isn't work done after the message.
  assert.deepEqual(turnReply(log(user(), started, call('b1', 'Bash'), text('Started the build; back when it finishes.'), call('e1', END))), { landed: true, replied: true });
});

test('turnReply: only the current turn counts, and a message from Mike mid-turn wants a reply of its own', () => {
  // Last turn's answer doesn't carry over.
  assert.deepEqual(turnReply(log(user(), { type: 'turn.started', turnId: 'turn-0' }, text('Earlier answer.'), { type: 'turn.completed', turnId: 'turn-0', outcome: 'completed', durationMs: 1 }, user('again'), started, call('e1', END))), { landed: true, replied: false });
  assert.deepEqual(turnReply(log(user(), started, text('Working on it.'), user('also do X'), call('e1', END))), { landed: true, replied: false });
  assert.deepEqual(turnReply(log(user(), started, text('Working on it.'), user('also do X'), text('Did X too.', 'm2'), call('e1', END))), { landed: true, replied: true });
});

test("turnReply: not landed until the call is in the events; a Codex child's items are ignored", () => {
  assert.deepEqual(turnReply(log(user(), started, text('Done.'))), { landed: false, replied: true });
  assert.deepEqual(turnReply(log(user(), started, call('b1', 'Bash'), result('b1'))), { landed: false, replied: false });
  // The child's text and its own end_turn are not the thread's.
  assert.deepEqual(turnReply(log(user(), started, text('Done.'), call('child/b1', 'Bash'), result('child/b1'), call('child/e1', END), call('e1', END))), { landed: true, replied: true });
});

// The 29 Oct refusals (threads 1edccf6f and ec75fe8b): the reply came as a
// thinking block signed as narration, straight before end_turn, after a
// create_thread result. Run the CLI's frames through the Claude normaliser
// as the runner does: that reply counts, and a plain thought still doesn't.
test('turnReply: a reply the CLI sent as a narration block counts; a thought before end_turn still does not', () => {
  const sig = (kind: string) => Buffer.concat([Buffer.from('0804128e110a11081318023801', 'hex'), Buffer.from([0x42, kind.length]), Buffer.from(kind)]).toString('base64');
  const turn = (kind: string) => {
    const n = new ClaudeNormalizer(fileContext('/work', '/nowhere/media', '/nowhere/blobs'));
    n.sent();
    const frame = (id: string, content: unknown[]) => ({ type: 'assistant', message: { id, content }, parent_tool_use_id: null });
    const evs = [
      frame('m1', [{ type: 'tool_use', id: 'c1', name: 'mcp__threadbear__create_thread', input: {} }]),
      { type: 'user', message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: 'c1', content: 'Started thread 3fee4428' }] }, parent_tool_use_id: null },
      frame('m2', [{ type: 'thinking', thinking: 'Wrap up.', signature: sig('thinking') }]),
      frame('m2', [{ type: 'thinking', thinking: "I've started a thread to fix the refusals.", signature: sig(kind) }]),
      frame('m2', [{ type: 'tool_use', id: 'e1', name: END, input: { needs: 'nothing' } }]),
    ]
      .flatMap((m) => n.handle(m))
      .flatMap((o) => (o.kind === 'event' ? [o.event as Record<string, unknown> & { type: string }] : []));
    return turnReply(log(user(), started, ...evs));
  };
  assert.deepEqual(turn('narration'), { landed: true, replied: true });
  assert.deepEqual(turn('thinking'), { landed: true, replied: false });
});

test("end_turn's description asks for the words naming a link's target to be that link", () => {
  // Mike, 29 Oct: plain "the screenshots in Highlights" over a button for the same screenshot.
  for (const d of [END_TURN_DESCRIPTION, CODEX_END_TURN_DESCRIPTION]) assert.match(d, /make those words a link to the same url/);
});
