// Mike's own threads, signed in: the Mac app's window in a browser. The
// sidebar's Starred, Inbox and Running sections with Hibernating and
// Archived folded under them; a thread with each finished turn folded to
// "Worked for 4m 12s" and its reply, and the agent's card of asks joined to
// the composer. A shared thread (/s/<slug>) is share.tsx.
import { Component, Fragment, useEffect, useMemo, useRef, useState, type ReactNode } from 'react';
import { useMutation, useQuery } from 'convex/react';
import { ConvexError } from 'convex/values';
import { api } from '../../convex/_generated/api';
import type { Id } from '../../convex/_generated/dataModel';
import { go, threadPath, useRoute } from './route';
import { signOut, useToken } from './token';
import { MessageText, Pictures, picturesByRow, ToolRun, Worked, type PageMessage } from './messages';
import { CommandState } from './command-state';
import { previewOf, ShareControl, SharePage } from './share';
import { duration, fold, splitTurns, type Item } from './turns';
import { ago, folderName, plain, sender } from './format';
import * as Icon from './icons';

type Row = NonNullable<ReturnType<typeof useQuery<typeof api.phone.threads>>>[number];
type Approval = NonNullable<Row['pendingApproval']>;
type Ask = NonNullable<Row['asks']>[number];

export function App() {
  const token = useToken();
  const route = useRoute();
  // A shared thread is for anyone, signed in or not.
  if (route.page === 'share') return <SharePage key={route.slug} slug={route.slug} token={token} />;
  if (!token) return <SignIn />;
  // Keyed on the token so a fresh sign-in clears an earlier auth error.
  return (
    <Catch key={token}>
      <Shell token={token} route={route} />
    </Catch>
  );
}

// ------------------------------------------------------------ sign-in

function SignIn({ expired }: { expired?: boolean }) {
  return (
    <main className="signin">
      <img src="/icon.png" alt="" width={72} height={72} />
      <h1>Threadbear</h1>
      <p>{expired ? 'This browser’s sign-in has expired or been revoked.' : 'This browser isn’t signed in yet.'}</p>
      <p>On the Mac, open Threadbear, then Settings › Phone &amp; browser › Open signed in.</p>
      <p className="muted small">
        It opens this site in your browser, signed in. From a terminal instead, in the repo: <code>npm run web:sign-in</code> (add <code>-- --qr</code> for a code to scan on another device).
      </p>
    </main>
  );
}

// Auth and missing-thread errors from Convex land here rather than as a
// blank page.
class Catch extends Component<{ children: ReactNode }, { error: unknown }> {
  state = { error: null as unknown };
  static getDerivedStateFromError(error: unknown) {
    return { error };
  }
  render() {
    const { error } = this.state;
    if (!error) return this.props.children;
    const kind = error instanceof ConvexError ? (error.data as { kind?: string })?.kind : undefined;
    if (kind === 'auth') return <SignIn expired />;
    return (
      <main className="signin">
        <h1>{kind === 'notFound' ? 'No such thread' : 'Something went wrong'}</h1>
        <p className="muted">{kind === 'notFound' ? 'It may have been deleted, or the Mac hasn’t mirrored it yet.' : String(error)}</p>
        <p>
          <a
            href="/"
            onClick={(e) => {
              e.preventDefault();
              this.setState({ error: null });
              go('/');
            }}
          >
            Back to the threads
          </a>
        </p>
      </main>
    );
  }
}

// ------------------------------------------------------------ layout

function Shell({ token, route }: { token: string; route: ReturnType<typeof useRoute> }) {
  const selected = route.page === 'thread' ? route.threadId : undefined;
  return (
    <div className={`shell ${selected ? 'has-thread' : ''}`}>
      <aside className="sidebar">
        <header className="bar">
          <a
            className="brand"
            href="/"
            onClick={(e) => {
              e.preventDefault();
              go('/');
            }}
          >
            <img src="/icon.png" alt="" width={22} height={22} />
            Threadbear
          </a>
          <Runners token={token} />
        </header>
        <Lists token={token} selected={selected} />
        <footer className="foot">
          <span>Signed in on this browser</span>
          <span>·</span>
          <button className="linkish" onClick={signOut}>
            Sign out
          </button>
        </footer>
      </aside>
      <main className="main">{selected ? <ThreadView key={selected} token={token} threadId={selected} /> : <Empty />}</main>
    </div>
  );
}

function Empty() {
  return (
    <div className="empty">
      <img src="/icon.png" alt="" width={88} height={88} />
      <p>Pick a thread.</p>
    </div>
  );
}

function Runners({ token }: { token: string }) {
  const runners = useQuery(api.phone.runners, { token });
  if (!runners) return null;
  const online = runners.filter((r) => Date.now() - Date.parse(r.lastSeenAt) < 3 * 60_000);
  const names = online.map((r) => r.name).join(', ');
  return (
    <span className="runners" title={online.length ? `Online: ${names}` : 'No runner online. Messages wait until the Mac is back.'}>
      <span className={`dot ${online.length ? 'ok' : ''}`} />
      {online.length ? names : 'Mac offline'}
    </span>
  );
}

// ------------------------------------------------------------ list

const busy = (r: Row) => r.status === 'running' || r.status === 'starting';

// As the Mac's sidebar: Starred, Inbox (what needs Mike first), Running,
// then Hibernating and Archived folded, loaded only while open.
function Lists({ token, selected }: { token: string; selected?: string }) {
  const inbox = useQuery(api.phone.threads, { token, view: 'inbox' });
  const counts = useQuery(api.phone.counts, { token });
  const [open, setOpen] = useState<{ hibernating: boolean; den: boolean }>({ hibernating: false, den: false });
  useTick();
  if (!inbox) return <div className="lists muted pad">Loading…</div>;
  const starred = inbox.filter((r) => r.starredAt);
  const rest = inbox.filter((r) => !r.starredAt);
  const running = rest.filter((r) => busy(r) && !r.needsYou);
  const waiting = rest.filter((r) => !running.includes(r));
  const sorted = [...waiting.filter((r) => r.needsYou), ...waiting.filter((r) => !r.needsYou)];
  return (
    <nav className="lists">
      {starred.length ? (
        <Section icon={<Icon.Star />} title="Starred">
          <Rows rows={starred} selected={selected} />
        </Section>
      ) : null}
      <Section icon={<Icon.Inbox />} title="Inbox">
        {sorted.length ? <Rows rows={sorted} selected={selected} /> : <div className="list note">Nothing waiting.</div>}
      </Section>
      {running.length ? (
        <Section icon={<Icon.Bolt />} title="Running" count={running.length}>
          <Rows rows={running} selected={selected} />
        </Section>
      ) : null}
      <Folded token={token} view="hibernating" icon={<Icon.Moon />} title="Hibernating" count={counts?.hibernating} open={open.hibernating} toggle={() => setOpen((o) => ({ ...o, hibernating: !o.hibernating }))} selected={selected} />
      <Folded token={token} view="den" icon={<Icon.Archive />} title="Archived" count={counts?.den} open={open.den} toggle={() => setOpen((o) => ({ ...o, den: !o.den }))} selected={selected} />
    </nav>
  );
}

function Section({ icon, title, count, children }: { icon: ReactNode; title: string; count?: number; children: ReactNode }) {
  return (
    <>
      <div className="section-head">
        {icon}
        {title}
        {count !== undefined ? <span className="count">{count}</span> : null}
      </div>
      {children}
    </>
  );
}

function Folded({ token, view, icon, title, count, open, toggle, selected }: { token: string; view: 'hibernating' | 'den'; icon: ReactNode; title: string; count?: number; open: boolean; toggle: () => void; selected?: string }) {
  const rows = useQuery(api.phone.threads, open ? { token, view } : 'skip');
  return (
    <>
      <button className={`section-head ${open ? 'open' : ''}`} onClick={toggle} aria-expanded={open}>
        {icon}
        {title}
        <span className="count">{count ?? ''}</span>
        <Icon.Chevron className="chev" />
      </button>
      {open ? rows ? rows.length ? <Rows rows={rows} selected={selected} /> : <div className="list note">Nothing here.</div> : <div className="list note">Loading…</div> : null}
    </>
  );
}

function Rows({ rows, selected }: { rows: Row[]; selected?: string }) {
  return (
    <ul className="list">
      {rows.map((r) => (
        <li key={r.threadId}>
          <a
            href={threadPath(r.threadId)}
            className={`row ${r.threadId === selected ? 'on' : ''} ${r.unread ? 'unread' : ''} ${r.needsYou ? 'needs' : ''}`}
            onClick={(e) => {
              if (e.metaKey || e.ctrlKey) return;
              e.preventDefault();
              go(threadPath(r.threadId));
            }}
          >
            <span className="row-top">
              {r.needsYou ? <span className="mark needs" title="Needs you" /> : r.unread ? <span className="mark unread" title="Unread" /> : null}
              <span className="title">{r.title || 'Untitled'}</span>
              {r.share?.access === 'link' ? (
                <span className="shared" title="Shared by link">
                  <Icon.Link />
                </span>
              ) : null}
              <When row={r} />
            </span>
            <span className="sub">{r.working && busy(r) ? r.working : r.projects?.length ? r.projects.map((p) => p.title).join(', ') : r.preview ? plain(r.preview) : folderName(r.cwd)}</span>
          </a>
        </li>
      ))}
    </ul>
  );
}

// The time at the right of a row, or the status instead of it, as the Mac.
function When({ row: r }: { row: Row }) {
  if (busy(r) && !r.needsYou) {
    return (
      <span className="when running" title="Working">
        <span className="spinner" />
      </span>
    );
  }
  if (r.status === 'error') return <span className="when failed">Failed</span>;
  return (
    <span className={`when ${r.needsYou ? 'waiting' : ''}`} title={r.needsYou ? 'Waiting for you' : undefined}>
      {ago(r.lastActivityMs)}
    </span>
  );
}

// ------------------------------------------------------------ thread

// How many messages (tool lines included) a thread opens with, and how many
// more each "Load earlier messages" adds. One live query covers them all, so
// it reads Convex alone and works while the Mac is asleep.
const FIRST_PAGE = 80;
const MORE = 200;

function ThreadView({ token, threadId }: { token: string; threadId: string }) {
  const data = useQuery(api.phone.thread, { token, threadId });
  const [limit, setLimit] = useState(FIRST_PAGE);
  const page = useQuery(api.phone.messages, { token, threadId, limit, tools: true });
  // For thread: links, as agents may give only the start of an id.
  const inbox = useQuery(api.phone.threads, { token, view: 'inbox' });
  const update = useMutation(api.phone.update);
  const [pending, setPending] = useState<Id<'commands'> | null>(null);
  const bottom = useRef<HTMLDivElement>(null);
  const list = useRef<HTMLDivElement>(null);
  const keepFromBottom = useRef<number | null>(null);
  const seen = useRef(false);
  // Keeps the last page on screen while a bigger one loads.
  const [shown, setShown] = useState<typeof page>(undefined);
  useEffect(() => {
    if (page) setShown(page);
  }, [page]);

  const lastSeq = shown?.messages.at(-1)?.seq;
  useEffect(() => {
    bottom.current?.scrollIntoView({ block: 'end' });
  }, [lastSeq, data?.thread.status]);
  // After loading earlier messages, stay where you were rather than jumping.
  useEffect(() => {
    const el = list.current;
    if (!el || keepFromBottom.current === null) return;
    el.scrollTop = el.scrollHeight - keepFromBottom.current;
    keepFromBottom.current = null;
  }, [shown]);

  // Opening a thread here counts as reading it, like opening it on the Mac.
  useEffect(() => {
    if (!data || seen.current) return;
    seen.current = true;
    if (data.thread.unread || data.thread.needsYou) void update({ token, threadId, change: { markSeen: true } });
  }, [data, token, threadId, update]);

  useEffect(() => {
    if (data) document.title = `${data.thread.title || 'Untitled'} · Threadbear`;
    return () => {
      document.title = 'Threadbear';
    };
  }, [data?.thread.title]);

  const messages = (shown?.messages ?? []) as PageMessage[];
  const t = data?.thread;
  const items = useMemo(() => fold(messages, t ? busy(t) : false), [messages, t?.status]);
  if (!data || !shown || !t) return <div className="pad muted">Loading…</div>;

  const pictures = shown.images ?? [];
  const inText = new Map(pictures.filter((p) => p.src).map((p) => [p.src!, p.url]));
  const after = picturesByRow(messages, pictures);
  const linkTo = (id: string) => threadPath(inbox?.find((r) => r.threadId.startsWith(id))?.threadId ?? id);
  const act = async (change: Parameters<typeof update>[0]['change']) => setPending(await update({ token, threadId, change }));

  // The meta line under the last reply: how long its turn took and what the
  // thread has cost, as on the Mac.
  const lastTurn = splitTurns(messages).at(-1);
  const lastReply = [...items].reverse().find((i) => i.kind === 'message');
  const meta = !busy(t) && lastReply?.kind === 'message' && lastReply.m.role === 'assistant' ? [lastTurn?.ms && lastTurn.ms >= 1000 ? duration(lastTurn.ms) : null, t.costUsd ? `$${t.costUsd.toFixed(2)}` : null].filter(Boolean).join(' · ') : '';

  const text = (m: PageMessage) => <MessageText text={m.text} pictures={inText} seq={m.seq} rows={messages} threadPath={linkTo} />;
  const renderItem = (item: Item<PageMessage>): ReactNode => {
    if (item.kind === 'worked') {
      return (
        <Worked key={`w${item.key}`} ms={item.ms}>
          {item.items.map((w) => (w.kind === 'tools' ? <ToolRun key={w.items[0]!.seq} items={w.items} open /> : renderItem(w)))}
        </Worked>
      );
    }
    if (item.kind === 'tools') {
      return (
        <div key={item.items[0]!.seq}>
          <ToolRun items={item.items} />
          <Pictures items={item.items.flatMap((m) => after.get(m.seq) ?? [])} />
        </div>
      );
    }
    const m = item.m;
    const from = sender(m);
    return (
      <div key={m.seq} className={`msg ${m.role}`}>
        {from ? <div className="origin">{from.who}</div> : m.role === 'user' && m.origin && m.origin !== 'user' && m.origin !== 'phone' ? <div className="origin">{originLabel(m.origin)}</div> : null}
        {from ? <MessageText text={from.body} pictures={inText} seq={m.seq} rows={messages} threadPath={linkTo} /> : text(m)}
        <Pictures items={after.get(m.seq) ?? []} />
      </div>
    );
  };

  return (
    <article className="thread">
      <header className="thread-head">
        <button className="icon-btn back" onClick={() => go('/')} aria-label="Back to the threads" title="Back to the threads">
          <Icon.Back />
        </button>
        <div className="crumbs" title={t.cwd}>
          <span className="folder">{folderName(t.cwd)}</span>
          <span className="sep">/</span>
          <h1>{t.title || 'Untitled'}</h1>
        </div>
        <ShareControl token={token} threadId={threadId} share={t.share} preview={previewOf(t.title, messages, pictures)} />
        <MoreMenu
          items={[
            { label: 'Copy link', run: () => void navigator.clipboard.writeText(location.origin + location.pathname) },
            { label: t.starredAt ? 'Unstar' : 'Star', run: () => void act({ star: !t.starredAt }) },
            t.view === 'hibernating' || t.snoozedUntil ? { label: 'Wake', run: () => void act({ wake: true }) } : t.view === 'inbox' ? { label: 'Hibernate', run: () => void act({ snooze: { untilRestart: true } }) } : null,
            t.view === 'den' ? { label: 'Bring back', run: () => void act({ unarchive: true }) } : { label: 'Archive', run: () => void act({ archive: true }) },
          ]}
        />
      </header>

      <div className="messages" ref={list}>
        {shown.hasMore ? (
          <button
            className="btn earlier"
            disabled={page !== shown}
            onClick={() => {
              const el = list.current;
              keepFromBottom.current = el ? el.scrollHeight - el.scrollTop : null;
              setLimit((n) => n + MORE);
            }}
          >
            {page !== shown ? 'Loading…' : 'Load earlier messages'}
          </button>
        ) : null}
        {items.map(renderItem)}
        {meta ? <div className="meta">{meta}</div> : null}
        {busy(t) ? (
          <div className="working">
            <span className="spinner" /> {t.working || 'Working…'}
          </div>
        ) : t.status === 'error' ? (
          <div className="failed-note">The last turn failed. Send a message to try again.</div>
        ) : null}
        <div ref={bottom} />
      </div>

      <div className="dock">
        {pending ? <CommandState token={token} commandId={pending} onDone={() => setPending(null)} /> : null}
        <Dock token={token} thread={t} lastSeq={lastSeq} onSent={setPending} onArchive={() => void act({ archive: true })} />
      </div>
    </article>
  );
}

function MoreMenu({ items }: { items: ({ label: string; run: () => void } | null)[] }) {
  const ref = useRef<HTMLDetailsElement>(null);
  useEffect(() => {
    const close = (e: MouseEvent) => {
      if (ref.current && !ref.current.contains(e.target as Node)) ref.current.open = false;
    };
    window.addEventListener('click', close);
    return () => window.removeEventListener('click', close);
  }, []);
  return (
    <details className="pop" ref={ref}>
      <summary className="icon-btn" title="More" aria-label="More">
        <Icon.More />
      </summary>
      <div className="pop-panel menu">
        {items.map((i) =>
          i ? (
            <button
              key={i.label}
              onClick={() => {
                i.run();
                if (ref.current) ref.current.open = false;
              }}
            >
              {i.label}
            </button>
          ) : null,
        )}
      </div>
    </details>
  );
}

// ------------------------------------------------------------ the dock

// What sits at the bottom, in one rounded box as on the Mac: an approval or
// question the CLI is waiting on, else the end_turn card of asks, else the
// done card's follow-ups, then the composer under it.
function Dock({ token, thread: t, lastSeq, onSent, onArchive }: { token: string; thread: Row; lastSeq?: number; onSent: (id: Id<'commands'>) => void; onArchive: () => void }) {
  const send = useMutation(api.phone.send);
  const [text, setText] = useState('');
  // Picks on the card of asks: ask index to choice index, for one card.
  const [picks, setPicks] = useState<{ card?: number; by: Record<number, number> }>({ by: {} });
  const [ticked, setTicked] = useState<{ seq?: number; set: Set<number> }>({ set: new Set() });
  const asks = !busy(t) && !t.pendingApproval ? (t.asks ?? []) : [];
  const by = picks.card === t.asksSeq ? picks.by : {};
  const done = !busy(t) && !t.needsYou && !t.pendingApproval && !asks.length && !t.archivedAt && !t.working && (t.next?.length ?? 0) > 0;
  const next = done ? (t.next ?? []) : [];
  const follow = ticked.seq === lastSeq ? [...ticked.set].sort().map((i) => next[i]).filter((x): x is string => !!x) : [];

  const submit = async () => {
    const answers = asks.flatMap((a, i) => (by[i] !== undefined && choices(a)[by[i]!] !== undefined ? [{ index: i, action: a.action, answer: choices(a)[by[i]!]! }] : []));
    const extra = text.trim();
    const body = follow.length ? followUpMessage(follow, extra) : answers.length ? answerMessage(asks.length, answers, extra) : extra;
    if (!body) return;
    setText('');
    setPicks({ by: {} });
    setTicked({ set: new Set() });
    onSent(await send({ token, threadId: t.threadId, text: body, ...(answers.length ? { answers: answers.map(({ action, answer }) => ({ action, answer })) } : {}) }));
  };

  const card = t.pendingApproval ? (
    <ApprovalCard token={token} threadId={t.threadId} approval={t.pendingApproval} onSent={onSent} />
  ) : asks.length ? (
    <section className="card">
      <h2>
        ✋ {asks.length === 1 ? 'Decision needed' : 'Decisions needed'}
      </h2>
      {asks.map((a, i) => (
        <Fragment key={i}>
          <div className="ask-q">
            <MessageText text={`${asks.length > 1 ? `${i + 1}. ` : ''}${a.action.replace(/\s*\n\s*/g, ' ').trim()}`} />
            {a.why?.trim() ? (
              <div className="ask-why">
                <MessageText text={a.why.trim()} />
              </div>
            ) : null}
          </div>
          {a.links?.length ? (
            <div className="ask-links">
              {a.links.map((l) => (
                <a key={l.url} className="btn primary" href={l.url} target="_blank" rel="noreferrer">
                  {l.title} ↗
                </a>
              ))}
            </div>
          ) : null}
          {choices(a).length ? (
            <div className="choices">
              {choices(a).map((c, n) => (
                <button key={n} className={`choice ${by[i] === n ? 'on' : ''}`} onClick={() => setPicks({ card: t.asksSeq, by: { ...by, [i]: by[i] === n ? -1 : n } })}>
                  <span className="radio" />
                  <span>
                    {c}
                    {a.suggested === n ? <span className="pick">my pick</span> : null}
                  </span>
                </button>
              ))}
            </div>
          ) : null}
        </Fragment>
      ))}
    </section>
  ) : next.length ? (
    <section className="card">
      <h2>
        Done
        <button className="btn plain" style={{ marginLeft: 'auto' }} onClick={onArchive}>
          Archive
        </button>
      </h2>
      <div className="choices">
        {next.map((n, i) => {
          const on = ticked.seq === lastSeq && ticked.set.has(i);
          return (
            <button
              key={i}
              className={`choice ${on ? 'on' : ''}`}
              onClick={() => {
                const set = new Set(ticked.seq === lastSeq ? ticked.set : []);
                if (on) set.delete(i);
                else set.add(i);
                setTicked({ seq: lastSeq, set });
              }}
            >
              <span className="radio check" />
              <span>{n}</span>
            </button>
          );
        })}
      </div>
    </section>
  ) : null;

  const ready = !!text.trim() || Object.values(by).some((n) => n >= 0) || follow.length > 0;
  return (
    <div className={`box ${t.pendingApproval || asks.length ? 'asking' : ''}`}>
      {card}
      <form
        className="composer"
        onSubmit={(e) => {
          e.preventDefault();
          void submit();
        }}
      >
        <textarea
          value={text}
          rows={Math.min(10, Math.max(1, text.split('\n').length))}
          placeholder={busy(t) ? 'Steer the agent' : asks.length ? 'Reply, or pick above' : 'Reply'}
          onChange={(e) => setText(e.target.value)}
          onKeyDown={(e) => {
            // Return sends, Shift-Return is a new line, as on the Mac. On a
            // phone's keyboard Return is a new line and the button sends.
            if (e.key === 'Enter' && !e.shiftKey && !e.nativeEvent.isComposing && !matchMedia('(pointer: coarse)').matches) {
              e.preventDefault();
              void submit();
            }
          }}
        />
        <div className="tools-row">
          <span className="grow" />
          <button className="send" disabled={!ready} aria-label="Send" title="Send">
            <Icon.Up />
          </button>
        </div>
      </form>
    </div>
  );
}

// What an ask offers: its options, else the reply it wants ("done").
function choices(a: Ask): string[] {
  if (a.options?.length) return a.options;
  return a.reply?.trim() ? [a.reply.trim()] : [];
}

// The message the Mac sends for picked asks (Decisions.message): each
// question then its answer, numbered when the card had several, then
// anything else typed.
function answerMessage(count: number, answers: { index: number; action: string; answer: string }[], extra: string): string {
  const parts = answers.map((a) => (count === 1 ? `${a.action}\n${a.answer}` : `${a.index + 1}. ${a.action}\n   ${a.answer.replace(/\n/g, '\n   ')}`));
  if (extra) parts.push(extra);
  return parts.join('\n\n');
}

// Ticked follow-ups (Decisions.followUpMessage): one on its own, several as
// a list, then anything else typed.
function followUpMessage(follow: string[], extra: string): string {
  let body = follow.length === 1 ? follow[0]! : follow.map((f) => `- ${f}`).join('\n');
  if (extra) body += `\n\n${extra}`;
  return body;
}

function ApprovalCard({ token, threadId, approval, onSent }: { token: string; threadId: string; approval: Approval; onSent: (id: Id<'commands'>) => void }) {
  const respond = useMutation(api.phone.respond);
  const answer = useMutation(api.phone.answer);
  const [answers, setAnswers] = useState<Record<string, string[]>>({});

  if (approval.kind === 'approval') {
    const label = { allow: 'Allow', allowAlways: 'Always allow', deny: 'Deny' } as Record<string, string>;
    return (
      <section className="card">
        <h2>{approval.title || approval.name}</h2>
        {approval.inputSummary ? <pre className="approval-input">{approval.inputSummary}</pre> : null}
        <div className="ask-links">
          {approval.options.map((o) => (
            <button key={o} className={`btn ${o === 'allow' ? 'primary' : ''}`} onClick={async () => onSent(await respond({ token, threadId, approvalId: approval.approvalId, decision: o as 'allow' | 'allowAlways' | 'deny' }))}>
              {label[o] ?? o}
            </button>
          ))}
        </div>
      </section>
    );
  }

  const ready = approval.questions.every((q) => answers[q.question]?.length);
  return (
    <section className="card">
      {approval.questions.map((q) => (
        <Fragment key={q.question}>
          <div className="ask-q">{q.question}</div>
          <div className="choices">
            {q.options.map((o) => {
              const chosen = answers[q.question]?.includes(o.label) ?? false;
              return (
                <button
                  key={o.label}
                  className={`choice ${chosen ? 'on' : ''}`}
                  onClick={() =>
                    setAnswers((a) => {
                      const cur = a[q.question] ?? [];
                      const next = q.multiSelect ? (chosen ? cur.filter((x) => x !== o.label) : [...cur, o.label]) : [o.label];
                      return { ...a, [q.question]: next };
                    })
                  }
                >
                  <span className={`radio ${q.multiSelect ? 'check' : ''}`} />
                  <span>
                    {o.label}
                    {o.description ? <span className="desc">{o.description}</span> : null}
                  </span>
                </button>
              );
            })}
          </div>
        </Fragment>
      ))}
      <div className="ask-links">
        <button
          className="btn primary"
          disabled={!ready}
          onClick={async () => {
            // Multi-select choices go in one comma-joined string, as the Mac app sends them.
            const flat = Object.fromEntries(Object.entries(answers).map(([k, v]) => [k, v.join(', ')]));
            onSent(await answer({ token, threadId, approvalId: approval.approvalId, answers: flat }));
          }}
        >
          Answer
        </button>
      </div>
    </section>
  );
}

// ------------------------------------------------------------ bits

function originLabel(origin: string): string {
  return origin === 'schedule' ? 'Scheduled' : origin === 'runner' ? 'From Threadbear' : origin === 'agent' ? 'From another thread' : origin;
}

// Re-renders every half minute so "5m" stays honest between query updates.
function useTick() {
  const [, setNow] = useState(0);
  useEffect(() => {
    const t = setInterval(() => setNow(Date.now()), 30_000);
    return () => clearInterval(t);
  }, []);
}
