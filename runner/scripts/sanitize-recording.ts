// Turns a raw SDK message recording (one JSON message per line, made with a
// throwaway query() script) into a small fixture that's safe to commit:
//   node scripts/sanitize-recording.ts raw.ndjson out.ndjson /abs/cwd/of/recording
// Drops hook output (it carries private skill text), rate limit and timing
// noise, trims system/init, rewrites the recording folder to /work/proj and
// replaces thinking text and signatures with placeholders.
import fs from 'node:fs';

const [raw, outFile, cwd] = process.argv.slice(2);
if (!raw || !outFile || !cwd) {
  console.error('usage: sanitize-recording.ts raw.ndjson out.ndjson /abs/cwd');
  process.exit(1);
}

const DROP_SUBTYPES = new Set(['hook_started', 'hook_response', 'hook_progress', 'thinking_tokens', 'status']);
const thinkingText = new Map<string, string>(); // `${msgId}:${index}` -> replaced text so far
let curMsg = '';
const blockCount = new Map<string, number>();

const lines = fs.readFileSync(raw, 'utf8').split('\n').filter(Boolean);
const out: string[] = [];
for (const line of lines) {
  const m = JSON.parse(line);
  if (m.__canUseTool || m.__interruptReturned || m.t === undefined && m.type === undefined) continue;
  delete m.t;
  if (m.type === 'rate_limit_event') continue;
  if (m.type === 'system' && DROP_SUBTYPES.has(m.subtype)) continue;
  if (m.type === 'system' && m.subtype === 'init') {
    out.push(JSON.stringify({ type: 'system', subtype: 'init', session_id: m.session_id, model: m.model, cwd: '/work/proj', permissionMode: m.permissionMode, tools: [], uuid: m.uuid }));
    continue;
  }
  if (m.type === 'stream_event') {
    if (m.api_message_id) curMsg = m.api_message_id;
    if (m.event?.type === 'message_start') curMsg = m.event.message.id;
    const d = m.event?.delta;
    if (d?.type === 'thinking_delta') {
      const key = `${curMsg}:${m.event.index}`;
      d.thinking = 'thinking ';
      thinkingText.set(key, (thinkingText.get(key) ?? '') + d.thinking);
    }
    if (d?.type === 'signature_delta') d.signature = 'sig';
  }
  if (m.type === 'assistant') {
    const id = m.message.id;
    for (const b of m.message.content) {
      const idx = blockCount.get(id) ?? 0;
      blockCount.set(id, idx + 1);
      if (b.type === 'thinking') {
        b.thinking = thinkingText.get(`${id}:${idx}`) ?? 'thinking ';
        b.signature = 'sig';
      }
    }
  }
  out.push(JSON.stringify(m).split(cwd).join('/work/proj').split(fs.realpathSync(cwd)).join('/work/proj'));
}
// Second pass: text deltas can split the recording path across chunks, so
// rebuild them from the (already rewritten) complete text of each block,
// keeping the same number of chunks.
const finalText = new Map<string, string>();
const deltaCount = new Map<string, number>();
const counts = new Map<string, number>();
let msgId = '';
const parsed = out.map((l) => JSON.parse(l));
for (const m of parsed) {
  if (m.type === 'stream_event') {
    if (m.api_message_id) msgId = m.api_message_id;
    if (m.event?.type === 'message_start') msgId = m.event.message.id;
    if (m.event?.delta?.type === 'text_delta') {
      const key = `${msgId}:${m.event.index}`;
      deltaCount.set(key, (deltaCount.get(key) ?? 0) + 1);
    }
  }
  if (m.type === 'assistant') {
    for (const b of m.message.content) {
      const idx = counts.get(m.message.id) ?? 0;
      counts.set(m.message.id, idx + 1);
      if (b.type === 'text') finalText.set(`${m.message.id}:${idx}`, b.text);
    }
  }
}
const used = new Map<string, number>();
for (const m of parsed) {
  if (m.type !== 'stream_event') continue;
  if (m.api_message_id) msgId = m.api_message_id;
  if (m.event?.type === 'message_start') msgId = m.event.message.id;
  const d = m.event?.delta;
  if (d?.type === 'input_json_delta') d.partial_json = '';
  if (d?.type !== 'text_delta') continue;
  const key = `${msgId}:${m.event.index}`;
  const text = finalText.get(key);
  if (text === undefined) continue;
  const n = deltaCount.get(key)!;
  const i = used.get(key) ?? 0;
  used.set(key, i + 1);
  const size = Math.ceil(text.length / n);
  d.text = text.slice(i * size, (i + 1) * size);
}
fs.writeFileSync(outFile, parsed.map((m) => JSON.stringify(m)).join('\n') + '\n');
console.log(`${out.length} messages -> ${outFile}`);
