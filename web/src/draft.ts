// A ```slack, ```email or ```draft block in a reply: text the agent has
// written for Mike to send somewhere else. It's shown the way it'll go out,
// every line where the agent put it (a reply's own Markdown joins lines up,
// which ran a Slack draft's "•" lines into one paragraph, 6 Nov), in a box
// with a Copy button. A ```slack one also draws Slack's own formatting:
// *bold*, _italic_, ~strike~, `code` and <url|label> links.
//
// Its twins are the Mac's app/Sources/ThreadbearCore/Markdown/DraftBlock.swift
// and the phone's ios/ThreadbearKit/Sources/ThreadbearKit/DraftBlock.swift:
// all three parse it the same way, so keep them together (and their tests,
// draft.test.ts here and DraftBlockTests on each of the others).

export type DraftKind = 'slack' | 'email' | 'draft';

export type Draft = { kind: DraftKind; source: string };

// A run of a line with one look. `link` is http(s) or mailto only.
export type Span = { text: string; bold?: boolean; italic?: boolean; strike?: boolean; code?: boolean; link?: string };

// `quote`: a Slack "> " line, drawn with a bar.
export type Line = { spans: Span[]; quote: boolean };

const kinds: readonly string[] = ['slack', 'email', 'draft'];

// The draft for a fence's info string (only the first word counts), or
// undefined for any other fence.
export function draftFrom(language: string | null | undefined, code: string): Draft | undefined {
  const word = language?.split(/[ \t{]/).find((w) => w !== '')?.toLowerCase();
  if (!word || !kinds.includes(word)) return undefined;
  const source = code.replace(/\r\n/g, '\n').replace(/\n+$/, '');
  if (!source.trim()) return undefined;
  return { kind: word as DraftKind, source };
}

// What the box's header calls it.
export function draftLabel(kind: DraftKind): string {
  return kind === 'slack' ? 'Slack draft' : kind === 'email' ? 'Email draft' : 'Draft';
}

// The draft's lines as they're shown. An email or plain draft is its text as
// it is; a Slack one has its formatting and <...> tokens worked out.
export function draftLines(draft: Draft): Line[] {
  return draft.source.split('\n').map((line) => {
    if (draft.kind !== 'slack') return { spans: [{ text: line }], quote: false };
    if (line.startsWith('> ') || line === '>' || line.startsWith('&gt; ')) {
      const rest = line.startsWith('&gt; ') ? line.slice(5) : line.slice(Math.min(2, line.length));
      return { spans: slackSpans(rest), quote: true };
    }
    return { spans: slackSpans(line), quote: false };
  });
}

// What Copy puts on the clipboard as plain text. A Slack draft keeps its
// *bold* and _italic_ (Slack's message box formats those as it sends) but
// its <url|label> links become "label (url)", which pasted as plain text
// would otherwise stay as typed.
export function draftPlainText(draft: Draft): string {
  if (draft.kind !== 'slack') return draft.source;
  return draft.source
    .split('\n')
    .map((line) =>
      replaceTokens(line, (token) => {
        if (token.kind === 'mention') return token.text;
        return token.label === token.url || token.label === '' ? token.url : `${token.label} (${token.url})`;
      }),
    )
    .join('\n');
}

// The same as HTML, put on the clipboard beside the plain text, so pasting
// into Slack or Mail keeps the bold and the links.
export function draftHTML(draft: Draft): string {
  const body = draftLines(draft).map((line) => {
    const inner = line.spans.map(spanHTML).join('');
    return line.quote ? `<blockquote>${inner}</blockquote>` : inner;
  });
  // Quotes are blocks of their own, so no <br> beside one.
  let out = '';
  body.forEach((part, index) => {
    out += part;
    if (index < body.length - 1 && !part.startsWith('<blockquote>') && !body[index + 1]!.startsWith('<blockquote>')) out += '<br>';
  });
  return `<meta charset="utf-8"><div>${out}</div>`;
}

function spanHTML(span: Span): string {
  let text = escapeHTML(span.text);
  if (span.code) text = `<code>${text}</code>`;
  if (span.strike) text = `<s>${text}</s>`;
  if (span.italic) text = `<i>${text}</i>`;
  if (span.bold) text = `<b>${text}</b>`;
  if (span.link) text = `<a href="${escapeHTML(span.link)}">${text}</a>`;
  return text;
}

function escapeHTML(text: string): string {
  return text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

// An email or plain draft's text with its bare http(s) addresses as links,
// for drawing only (Copy sends the text as written). Punctuation that ends
// a sentence after an address isn't part of it.
export function bareLinks(text: string): Span[] {
  const spans: Span[] = [];
  let at = 0;
  for (const m of text.matchAll(/https?:\/\/[^\s<>"]+/gi)) {
    const url = m[0].replace(/[.,;:!?'")\]]+$/, '');
    if (!URL.canParse(url) || url.length <= m[0].indexOf('//') + 2) continue;
    if (m.index > at) spans.push({ text: text.slice(at, m.index) });
    spans.push({ text: url, link: url });
    at = m.index + url.length;
  }
  if (at < text.length) spans.push({ text: text.slice(at) });
  return spans;
}

// MARK: Slack's formatting

// <@U123>, <#C123|general>, <!here> are mentions, shown as their words.
type Token = { kind: 'link'; url: string; label: string } | { kind: 'mention'; text: string };

// A <...> token: a link to a web page or a mail address, or a mention.
// Anything else between angle brackets is left as written.
export function token(inside: string): Token | undefined {
  const bar = inside.indexOf('|');
  const target = bar < 0 ? inside : inside.slice(0, bar);
  const label = bar < 0 ? undefined : inside.slice(bar + 1);
  const first = target[0];
  if (first === '@' || first === '#' || first === '!') {
    const name = target.slice(1);
    if (!name || name.includes(' ')) return undefined;
    if (label) return { kind: 'mention', text: first === '#' && !label.startsWith('#') ? `#${label}` : label };
    if (first === '!') {
      // <!subteam^S123> and <!date^...> carry a label or nothing useful.
      return { kind: 'mention', text: `@${name.split('^').find((p) => p !== '') ?? name}` };
    }
    return { kind: 'mention', text: `${first}${name}` };
  }
  // The Swift side's URL(string:) check; the address is kept as written
  // (a URL object would add a "/" to "https://x.dev").
  const scheme = /^([a-z][a-z0-9+.-]*):/i.exec(target)?.[1]?.toLowerCase();
  if (target.includes(' ') || !scheme || !['http', 'https', 'mailto'].includes(scheme) || !URL.canParse(target)) return undefined;
  const shown = label !== undefined ? decode(label) : scheme === 'mailto' ? target.slice('mailto:'.length) : target;
  return { kind: 'link', url: target, label: shown };
}

// The line with each <...> token replaced, and Slack's escapes (&lt; &gt;
// &amp;) read back.
function replaceTokens(line: string, replace: (token: Token) => string): string {
  let out = '';
  let rest = line;
  for (let open = rest.indexOf('<'); open >= 0; open = rest.indexOf('<')) {
    out += decode(rest.slice(0, open));
    const after = rest.slice(open + 1);
    const close = after.indexOf('>');
    const found = close >= 0 ? token(after.slice(0, close)) : undefined;
    if (!found) {
      out += '<';
      rest = after;
      continue;
    }
    out += replace(found);
    rest = after.slice(close + 1);
  }
  return out + decode(rest);
}

function decode(text: string): string {
  return text.replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&amp;/g, '&');
}

// A Slack line's spans: links and mentions first, then *bold*, _italic_,
// ~strike~ and `code` in the words between them.
export function slackSpans(line: string): Span[] {
  const spans: Span[] = [];
  let rest = line;
  for (let open = rest.indexOf('<'); open >= 0; open = rest.indexOf('<')) {
    const after = rest.slice(open + 1);
    const close = after.indexOf('>');
    const found = close >= 0 ? token(after.slice(0, close)) : undefined;
    if (!found) {
      // Not a token: the "<" is a word like any other.
      spans.push(...emphasis(rest.slice(0, open + 1)));
      rest = after;
      continue;
    }
    spans.push(...emphasis(rest.slice(0, open)));
    if (found.kind === 'link') spans.push({ text: found.label || found.url, link: found.url });
    else spans.push({ text: found.text, bold: true });
    rest = after.slice(close + 1);
  }
  spans.push(...emphasis(rest));
  return merge(spans);
}

const sameLook = (a: Span, b: Span) =>
  !!a.bold === !!b.bold && !!a.italic === !!b.italic && !!a.strike === !!b.strike && !!a.code === !!b.code && a.link === b.link;

// Joins neighbouring spans that look the same (a "<" that wasn't a token
// leaves the words around it in pieces).
function merge(spans: Span[]): Span[] {
  const out: Span[] = [];
  for (const span of spans) {
    if (!span.text) continue;
    const last = out[out.length - 1];
    if (last && sameLook(last, span)) out[out.length - 1] = { ...last, text: last.text + span.text };
    else out.push(span);
  }
  return out;
}

const wordy = (c: string | undefined) => c !== undefined && /[\p{L}\p{N}]/u.test(c);
const space = (c: string | undefined) => c !== undefined && /\s/u.test(c);

// Slack's emphasis: a marker counts when it opens at the start or after a
// space or punctuation, is followed by a non-space, and closes on the same
// line before a space, punctuation or the end. So "2*3*4" and
// "snake_case_name" stay as written. Works on code points, as the Swift
// side works on Characters.
function emphasis(text: string, base: Omit<Span, 'text'> = {}): Span[] {
  const chars = Array.from(text);
  const spans: Span[] = [];
  let plain = '';
  const flush = () => {
    if (!plain) return;
    spans.push({ ...base, text: decode(plain) });
    plain = '';
  };
  let i = 0;
  while (i < chars.length) {
    const c = chars[i]!;
    const end = '*_~`'.includes(c) && opens(chars, i) ? closing(chars, i, c) : undefined;
    if (end !== undefined) {
      flush();
      const inner = chars.slice(i + 1, end).join('');
      if (c === '`') spans.push({ ...base, code: true, text: decode(inner) });
      else spans.push(...emphasis(inner, { ...base, ...(c === '*' ? { bold: true } : c === '_' ? { italic: true } : { strike: true }) }));
      i = end + 1;
      continue;
    }
    plain += c;
    i += 1;
  }
  flush();
  return spans;
}

function opens(chars: string[], i: number): boolean {
  if (i + 1 >= chars.length || space(chars[i + 1]) || chars[i + 1] === chars[i]) return false;
  return i === 0 || !wordy(chars[i - 1]);
}

function closing(chars: string[], start: number, marker: string): number | undefined {
  for (let j = start + 2; j < chars.length; j++) {
    if (chars[j] === marker && !space(chars[j - 1]) && (j + 1 === chars.length || !wordy(chars[j + 1]))) return j;
  }
  return undefined;
}
