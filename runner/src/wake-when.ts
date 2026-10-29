// Wake when… (docs/protocol.md, "Hibernate in words"): Mike says in his own
// words when a hibernating thread should come back ("at the weekend", "in
// a few weeks", "next time I talk about woodworking") and the strong model
// turns that into a time, a topic to listen for, or both. A time is an
// ordinary snoozedUntil; a topic is the librarian's to notice, in the next
// thread Mike talks about it in (librarian.ts).

export type WakeWhen = {
  // What Mike typed.
  said: string;
  // What to listen for, when it's a topic ("woodworking").
  topic?: string;
  // Set while the model works it out. A runner that restarts meanwhile
  // puts the thread back in the inbox, as the answer is lost.
  pending?: true;
};

export type WakeAnswer = { until?: string; topic?: string; why: string };

export type WakeInput = {
  said: string;
  now: number;
  timeZone: string;
  title: string;
  first?: string;
  brief?: string;
};

// What Mike can type, and how far ahead a time can be.
export const SAID_MAX = 300;
export const TOPIC_MAX = 80;
const LATEST_MS = 2 * 365 * 86_400_000;

export const WAKE_SYSTEM = [
  "You work out when a hibernating thread should wake up, in Threadbear, Mike's app for running AI agents in threads. Mike has put a thread away and said in his own words when he wants it back.",
  'Answer with a time, a topic, or both:',
  '- A time when he names one, however loosely: "at the weekend" is Saturday 9 am, "tonight" 7 pm, "in a few weeks" three weeks on at 9 am, "after Christmas" 27 December 9 am. Pick a sensible hour when he gives none: 9 am for a day. Never a time that has already passed.',
  '- A topic when he wants it back the next time he brings something up ("next time I talk about woodworking", "when I get back to the shed"): a few words for what to listen for, as you would say it in "when Mike talks about …" ("woodworking", "the shed build"). Add a time as well only when he gives a limit ("or in a month at the latest").',
  "- Something you can't watch for (a reply from someone, a PR merging, a delivery): the time it's most likely to have happened by, and say so in why.",
  'Reply with JSON only, no prose and no code fence: {"until": "an ISO 8601 time with its UTC offset, or null", "topic": "a few words, or null", "why": "one short line, in plain words"}',
].join('\n\n');

export function wakePrompt(input: WakeInput): string {
  const parts = [
    `Now: ${localNow(input.now, input.timeZone)} (${input.timeZone})`,
    `The thread: "${input.title}"`,
  ];
  if (input.first) parts.push(`How it started (Mike): ${cut(input.first, 800)}`);
  if (input.brief) parts.push(`Where it's up to:\n${cut(input.brief, 600)}`);
  parts.push(`Mike wants it back: ${input.said.trim()}`);
  return parts.join('\n\n');
}

// The model's answer, or why it can't be used.
export function readWakeAnswer(text: string, now: number): WakeAnswer | { error: string } {
  const obj = parseObject(text);
  if (!obj) return { error: "The model's answer wasn't JSON." };
  const why = typeof obj.why === 'string' ? obj.why.trim().slice(0, 200) : '';
  const topic = typeof obj.topic === 'string' && obj.topic.trim() ? obj.topic.trim().replace(/[.\s]+$/, '').slice(0, TOPIC_MAX) : undefined;
  let until: string | undefined;
  if (typeof obj.until === 'string' && obj.until.trim()) {
    const t = Date.parse(obj.until);
    if (Number.isNaN(t)) return { error: `The model gave a time that couldn't be read: ${obj.until}` };
    if (t <= now + 60_000) return { error: why || 'That time has already passed.' };
    if (t > now + LATEST_MS) return { error: 'That is more than two years away.' };
    until = new Date(t).toISOString();
  }
  if (!until && !topic) return { error: why || "Couldn't work out when from that." };
  return { ...(until ? { until } : {}), ...(topic ? { topic } : {}), why };
}

// The note the thread gets: "Hibernating until Saturday 1 November, 9 am."
export function hibernateNote(answer: WakeAnswer, said: string, timeZone: string): string {
  const when = answer.until ? localWhen(Date.parse(answer.until), timeZone) : undefined;
  const head = answer.topic
    ? `Hibernating until you next talk about ${answer.topic}${when ? `, or ${when} at the latest` : ''}.`
    : `Hibernating until ${when}.`;
  return `${head} You said "${cut(said.trim(), 120)}".`;
}

// "Thursday 29 October 2026, 2:05 pm"
function localNow(now: number, timeZone: string): string {
  return new Date(now).toLocaleString('en-GB', { timeZone, weekday: 'long', day: 'numeric', month: 'long', year: 'numeric', hour: 'numeric', minute: '2-digit', hour12: true });
}

// "Saturday 1 November, 9 am"; "9:30 am" when it isn't on the hour.
export function localWhen(t: number, timeZone: string): string {
  const d = new Date(t);
  const day = d.toLocaleDateString('en-GB', { timeZone, weekday: 'long', day: 'numeric', month: 'long' }).replace(',', '');
  const time = d.toLocaleTimeString('en-GB', { timeZone, hour: 'numeric', minute: '2-digit', hour12: true }).replace(':00', '').replace(/\s?([ap])\.?m\.?/i, ' $1m');
  return `${day}, ${time}`;
}

const cut = (t: string, n: number) => (t.length > n ? t.slice(0, n) + '…' : t);

function parseObject(text: string): Record<string, unknown> | undefined {
  const t = text.trim().replace(/^```(?:json)?\s*/i, '').replace(/```\s*$/, '');
  const start = t.indexOf('{');
  const end = t.lastIndexOf('}');
  if (start < 0 || end <= start) return undefined;
  try {
    const v = JSON.parse(t.slice(start, end + 1)) as unknown;
    return v && typeof v === 'object' && !Array.isArray(v) ? (v as Record<string, unknown>) : undefined;
  } catch {
    return undefined;
  }
}
