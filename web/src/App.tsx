import { Component, useEffect, useRef, useState, type ReactNode } from 'react';
import { useMutation, useQuery } from 'convex/react';
import { ConvexError } from 'convex/values';
import { api } from '../../convex/_generated/api';
import type { Id } from '../../convex/_generated/dataModel';
import { go, threadPath, useRoute } from './route';
import { signOut, useToken } from './token';
import { groupTools, MessageText, Pictures, picturesByRow, ToolRun } from './messages';
import { CommandState } from './command-state';
import { ShareControl, SharePage } from './share';

type View = 'inbox' | 'hibernating' | 'den';
type Row = NonNullable<ReturnType<typeof useQuery<typeof api.phone.threads>>>[number];
type Approval = NonNullable<Row['pendingApproval']>;

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
      <p className="muted">
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
  const me = useQuery(api.phone.me, { token });
  const [view, setView] = useState<View>('inbox');
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
        <nav className="tabs">
          {(['inbox', 'hibernating', 'den'] as const).map((v) => (
            <button key={v} className={v === view ? 'on' : ''} onClick={() => setView(v)}>
              {v === 'inbox' ? 'Inbox' : v === 'hibernating' ? 'Hibernating' : 'Archived'}
            </button>
          ))}
        </nav>
        <ThreadList token={token} view={view} selected={selected} />
        <footer className="foot muted">
          {me ? <>Signed in as “{me.name}” until {new Date(me.expiresAt).toLocaleDateString()}. </> : null}
          <button className="link" onClick={signOut}>
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
    <div className="empty muted">
      <img src="/icon.png" alt="" width={96} height={96} />
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

function ThreadList({ token, view, selected }: { token: string; view: View; selected?: string }) {
  const rows = useQuery(api.phone.threads, { token, view });
  useTick();
  if (!rows) return <div className="list muted pad">Loading…</div>;
  if (!rows.length) return <div className="list muted pad">Nothing here.</div>;
  // Threads waiting on Mike float to the top of the inbox, as on the Mac.
  const sorted = view === 'inbox' ? [...rows.filter((r) => r.needsYou), ...rows.filter((r) => !r.needsYou)] : rows;
  return (
    <ul className="list">
      {sorted.map((r) => (
        <li key={r.threadId}>
          <a
            href={threadPath(r.threadId)}
            className={`row ${r.threadId === selected ? 'on' : ''} ${r.unread ? 'unread' : ''}`}
            onClick={(e) => {
              if (e.metaKey || e.ctrlKey) return;
              e.preventDefault();
              go(threadPath(r.threadId));
            }}
          >
            <span className="row-top">
              {r.needsYou ? <span className="badge">Needs you</span> : r.status === 'running' ? <span className="spinner" /> : null}
              <span className="title">{r.title || 'Untitled'}</span>
              <span className="when muted">{ago(r.lastActivityMs)}</span>
            </span>
            <span className="preview muted">{r.working || plain(r.preview)}</span>
          </a>
        </li>
      ))}
    </ul>
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
  }, [lastSeq]);
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

  if (!data || !shown) return <div className="pad muted">Loading…</div>;
  const t = data.thread;
  // A shared thread's pictures (only shared ones have any uploaded).
  const pictures = shown.images ?? [];
  const inText = new Map(pictures.filter((p) => p.src).map((p) => [p.src!, p.url]));
  const after = picturesByRow(shown.messages, pictures);

  const act = async (change: Parameters<typeof update>[0]['change']) => setPending(await update({ token, threadId, change }));

  return (
    <article className="thread">
      <header className="thread-head">
        <button className="back" onClick={() => go('/')} aria-label="Back">
          ‹
        </button>
        <div className="head-text">
          <h1>{t.title || 'Untitled'}</h1>
          <p className="muted small">
            {shortPath(t.cwd)} · {t.model ?? t.provider} · {t.accountId}
            {t.costUsd ? ` · $${t.costUsd.toFixed(2)}` : ''}
          </p>
        </div>
        <div className="head-actions">
          <ShareControl token={token} threadId={threadId} share={t.share} />
          <CopyLink />
          {t.view === 'hibernating' || t.snoozedUntil ? (
            <button onClick={() => act({ wake: true })}>Wake</button>
          ) : t.view === 'inbox' ? (
            <button onClick={() => act({ snooze: { untilRestart: true } })} title="Hibernate until you wake it">
              Hibernate
            </button>
          ) : null}
          {t.view === 'den' ? <button onClick={() => act({ unarchive: true })}>Bring back</button> : <button onClick={() => act({ archive: true })}>To the den</button>}
        </div>
      </header>

      <div className="messages" ref={list}>
        {shown.hasMore ? (
          <button
            className="earlier"
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
        {groupTools(shown.messages).map((g) =>
          g.kind === 'tools' ? (
            <div key={g.items[0]!.seq}>
              <ToolRun items={g.items} />
              <Pictures items={g.items.flatMap((m) => after.get(m.seq) ?? [])} />
            </div>
          ) : (
            <div key={g.m.seq} className={`msg ${g.m.role}`}>
              {g.m.role === 'user' && g.m.origin && g.m.origin !== 'user' ? <div className="origin muted small">{originLabel(g.m.origin)}</div> : null}
              <MessageText text={g.m.text} pictures={inText} />
              <Pictures items={after.get(g.m.seq) ?? []} />
              <div className="when muted small">{new Date(g.m.at).toLocaleString()}</div>
            </div>
          ),
        )}
        {t.status === 'running' ? (
          <div className="working muted">
            <span className="spinner" /> {t.working || 'Bear with me…'}
          </div>
        ) : null}
        <div ref={bottom} />
      </div>

      {t.pendingApproval ? <ApprovalCard token={token} threadId={threadId} approval={t.pendingApproval} onSent={setPending} /> : null}
      {pending ? <CommandState token={token} commandId={pending} onDone={() => setPending(null)} /> : null}
      <Composer token={token} threadId={threadId} onSent={setPending} />
    </article>
  );
}

function ApprovalCard({ token, threadId, approval, onSent }: { token: string; threadId: string; approval: Approval; onSent: (id: Id<'commands'>) => void }) {
  const respond = useMutation(api.phone.respond);
  const answer = useMutation(api.phone.answer);
  const [answers, setAnswers] = useState<Record<string, string[]>>({});

  if (approval.kind === 'approval') {
    const label = { allow: 'Allow', allowAlways: 'Always allow', deny: 'Deny' } as Record<string, string>;
    return (
      <section className="card ask">
        <h2>{approval.title || approval.name}</h2>
        {approval.inputSummary ? <pre className="input">{approval.inputSummary}</pre> : null}
        <div className="buttons">
          {approval.options.map((o) => (
            <button key={o} className={o === 'allow' ? 'primary' : ''} onClick={async () => onSent(await respond({ token, threadId, approvalId: approval.approvalId, decision: o as 'allow' | 'allowAlways' | 'deny' }))}>
              {label[o] ?? o}
            </button>
          ))}
        </div>
      </section>
    );
  }

  const ready = approval.questions.every((q) => answers[q.question]?.length);
  return (
    <section className="card ask">
      {approval.questions.map((q) => (
        <div key={q.question} className="question">
          <h2>{q.question}</h2>
          <div className="options">
            {q.options.map((o) => {
              const chosen = answers[q.question]?.includes(o.label) ?? false;
              return (
                <button
                  key={o.label}
                  className={`option ${chosen ? 'on' : ''}`}
                  onClick={() =>
                    setAnswers((a) => {
                      const cur = a[q.question] ?? [];
                      const next = q.multiSelect ? (chosen ? cur.filter((x) => x !== o.label) : [...cur, o.label]) : [o.label];
                      return { ...a, [q.question]: next };
                    })
                  }
                >
                  <strong>{o.label}</strong>
                  {o.description ? <span className="muted small">{o.description}</span> : null}
                </button>
              );
            })}
          </div>
        </div>
      ))}
      <div className="buttons">
        <button
          className="primary"
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

function Composer({ token, threadId, onSent }: { token: string; threadId: string; onSent: (id: Id<'commands'>) => void }) {
  const send = useMutation(api.phone.send);
  const [text, setText] = useState('');
  const submit = async () => {
    const body = text.trim();
    if (!body) return;
    setText('');
    onSent(await send({ token, threadId, text: body }));
  };
  return (
    <form
      className="composer"
      onSubmit={(e) => {
        e.preventDefault();
        void submit();
      }}
    >
      <textarea
        value={text}
        rows={Math.min(8, Math.max(2, text.split('\n').length))}
        placeholder="Message this thread (⌘↩ to send)"
        onChange={(e) => setText(e.target.value)}
        onKeyDown={(e) => {
          if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) {
            e.preventDefault();
            void submit();
          }
        }}
      />
      <button className="primary" disabled={!text.trim()}>
        Send
      </button>
    </form>
  );
}

function CopyLink() {
  const [copied, setCopied] = useState(false);
  return (
    <button
      onClick={async () => {
        await navigator.clipboard.writeText(location.origin + location.pathname);
        setCopied(true);
        setTimeout(() => setCopied(false), 1500);
      }}
    >
      {copied ? 'Copied' : 'Copy link'}
    </button>
  );
}

// ------------------------------------------------------------ bits

function originLabel(origin: string): string {
  return origin === 'phone' ? 'From the phone or web' : origin === 'schedule' ? 'Scheduled' : origin === 'runner' ? 'From Threadbear' : origin;
}

// The preview is the reply's first lines as Markdown; the list shows them as
// plain text.
function plain(md: string): string {
  return md
    .replace(/!?\[([^\]]*)\]\([^)]*\)/g, '$1')
    .replace(/[*`#>]+/g, '')
    .replace(/\s+/g, ' ')
    .trim();
}

function shortPath(p: string): string {
  return p.replace(/^\/Users\/[^/]+/, '~');
}

function ago(ms: number): string {
  const s = Math.max(0, (Date.now() - ms) / 1000);
  if (s < 60) return 'now';
  if (s < 3600) return `${Math.floor(s / 60)}m`;
  if (s < 86400) return `${Math.floor(s / 3600)}h`;
  if (s < 86400 * 7) return `${Math.floor(s / 86400)}d`;
  return new Date(ms).toLocaleDateString(undefined, { day: 'numeric', month: 'short' });
}

// Re-renders every half minute so "5m" stays honest between query updates.
function useTick() {
  const [, setNow] = useState(0);
  useEffect(() => {
    const t = setInterval(() => setNow(Date.now()), 30_000);
    return () => clearInterval(t);
  }, []);
}
