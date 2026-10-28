// A thread Mike shared (/s/<slug>; docs/website.md, "Sharing"). Read-only
// and for anyone the share lets in: with "anyone with the link" it just
// shows, with "specific people" the reader proves their address with a
// code emailed to it first. Mike's own sign-in, if this browser has one,
// lets him straight in.
import { useEffect, useRef, useState } from 'react';
import { useMutation, useQuery } from 'convex/react';
import { api } from '../../convex/_generated/api';
import { groupTools, MessageText, ToolRun } from './messages';

const FIRST_PAGE = 80;
const MORE = 200;

const viewerKey = (slug: string) => `threadbear.viewer.${slug}`;

export function SharePage({ slug, token }: { slug: string; token: string | null }) {
  const [viewer, setViewer] = useState(() => localStorage.getItem(viewerKey(slug)) ?? undefined);
  const [limit, setLimit] = useState(FIRST_PAGE);
  const data = useQuery(api.share.view, { slug, limit, ...(viewer ? { viewer } : {}), ...(token ? { token } : {}) });
  // Keeps the last page on screen while a bigger one loads.
  const [shown, setShown] = useState<typeof data>(undefined);
  useEffect(() => {
    if (data) setShown(data);
  }, [data]);

  const signedIn = (v: string) => {
    localStorage.setItem(viewerKey(slug), v);
    setViewer(v);
  };
  const signOut = () => {
    localStorage.removeItem(viewerKey(slug));
    setViewer(undefined);
  };

  const title = shown && shown.state !== 'gone' ? shown.title || 'Untitled' : undefined;
  useEffect(() => {
    document.title = title ? `${title} · Threadbear` : 'Threadbear';
  }, [title]);

  if (!shown) return <div className="pad muted">Loading…</div>;
  if (shown.state === 'gone') {
    return (
      <main className="signin">
        <img src="/icon.png" alt="" width={72} height={72} />
        <h1>This link doesn’t work</h1>
        <p className="muted">It may not be shared any more, or it has a new link now.</p>
      </main>
    );
  }
  if (shown.state === 'signIn') return <CodeSignIn slug={slug} title={shown.title} onSignedIn={signedIn} />;
  return <SharedThread data={shown} loading={data !== shown} onMore={() => setLimit((n) => n + MORE)} onSignOut={shown.email ? signOut : undefined} />;
}

type Shared = Extract<NonNullable<ReturnType<typeof useQuery<typeof api.share.view>>>, { state: 'ok' }>;

function SharedThread({ data, loading, onMore, onSignOut }: { data: Shared; loading: boolean; onMore: () => void; onSignOut?: () => void }) {
  const bottom = useRef<HTMLDivElement>(null);
  const list = useRef<HTMLDivElement>(null);
  const keepFromBottom = useRef<number | null>(null);
  const lastSeq = data.messages.at(-1)?.seq;
  useEffect(() => {
    bottom.current?.scrollIntoView({ block: 'end' });
  }, [lastSeq]);
  // After loading earlier messages, stay where you were rather than jumping.
  useEffect(() => {
    const el = list.current;
    if (!el || keepFromBottom.current === null) return;
    el.scrollTop = el.scrollHeight - keepFromBottom.current;
    keepFromBottom.current = null;
  }, [data]);

  return (
    <article className="thread shared">
      <header className="thread-head">
        <img src="/icon.png" alt="" width={26} height={26} />
        <div className="head-text">
          <h1>{data.title || 'Untitled'}</h1>
        </div>
        {onSignOut ? (
          <div className="head-actions">
            <span className="muted small">{data.email}</span>
            <button className="link" onClick={onSignOut}>
              Sign out
            </button>
          </div>
        ) : null}
      </header>
      <div className="messages" ref={list}>
        {data.hasMore ? (
          <button
            className="earlier"
            disabled={loading}
            onClick={() => {
              const el = list.current;
              keepFromBottom.current = el ? el.scrollHeight - el.scrollTop : null;
              onMore();
            }}
          >
            {loading ? 'Loading…' : 'Load earlier messages'}
          </button>
        ) : null}
        {groupTools(data.messages).map((g) =>
          g.kind === 'tools' ? (
            <ToolRun key={g.items[0]!.seq} items={g.items} />
          ) : (
            <div key={g.m.seq} className={`msg ${g.m.role}`}>
              <MessageText text={g.m.text} />
              <div className="when muted small">{new Date(g.m.at).toLocaleString()}</div>
            </div>
          ),
        )}
        {data.running ? (
          <div className="working muted">
            <span className="spinner" /> {data.working || 'Bear with me…'}
          </div>
        ) : null}
        <div ref={bottom} />
      </div>
    </article>
  );
}

// "Specific people": the reader's address, then the code sent to it.
function CodeSignIn({ slug, title, onSignedIn }: { slug: string; title: string; onSignedIn: (viewer: string) => void }) {
  const sendCode = useMutation(api.share.sendCode);
  const verifyCode = useMutation(api.share.verifyCode);
  const [email, setEmail] = useState('');
  const [code, setCode] = useState('');
  const [sentTo, setSentTo] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [problem, setProblem] = useState<string | null>(null);

  const send = async () => {
    setBusy(true);
    setProblem(null);
    try {
      const r = await sendCode({ slug, email });
      if (r.ok) setSentTo(email.trim());
      else setProblem(r.message ?? 'That didn’t work.');
    } finally {
      setBusy(false);
    }
  };
  const verify = async () => {
    setBusy(true);
    setProblem(null);
    try {
      const r = await verifyCode({ slug, email, code });
      if (r.ok) onSignedIn(r.viewer);
      else setProblem(r.message);
    } finally {
      setBusy(false);
    }
  };

  return (
    <main className="signin">
      <img src="/icon.png" alt="" width={72} height={72} />
      <h1>{title || 'Untitled'}</h1>
      {sentTo === null ? (
        <form
          className="code-form"
          onSubmit={(e) => {
            e.preventDefault();
            void send();
          }}
        >
          <p className="muted">This thread is shared with specific people. Enter your email for a code.</p>
          <input type="email" autoComplete="email" placeholder="you@example.com" value={email} onChange={(e) => setEmail(e.target.value)} autoFocus required />
          <button className="primary" disabled={busy || !email.trim()}>
            Send code
          </button>
        </form>
      ) : (
        <form
          className="code-form"
          onSubmit={(e) => {
            e.preventDefault();
            void verify();
          }}
        >
          {/* The same words whether or not the address is on the list. */}
          <p className="muted">If {sentTo} can read this thread, a code is on its way there.</p>
          <input inputMode="numeric" autoComplete="one-time-code" placeholder="123456" value={code} onChange={(e) => setCode(e.target.value)} autoFocus required />
          <button className="primary" disabled={busy || code.replace(/\D/g, '').length !== 6}>
            Open
          </button>
          <button
            type="button"
            className="link"
            onClick={() => {
              setSentTo(null);
              setCode('');
              setProblem(null);
            }}
          >
            Use another email
          </button>
        </form>
      )}
      {problem ? <p className="problem">{problem}</p> : null}
    </main>
  );
}
