// A thread shared by link (/s/<slug>; docs/website.md, "Sharing"):
// read-only, for anyone, with its pictures. When this browser is signed in
// as Mike the page also has ShareControl, so he can stop sharing it (it
// then reads "Only you" for him and is gone for everyone else) or share
// it again.
import { useEffect, useMemo, useRef, useState } from 'react';
import { useMutation, useQuery } from 'convex/react';
import { api } from '../../convex/_generated/api';
import type { Id } from '../../convex/_generated/dataModel';
import { groupTools, MessageText, Pictures, picturesByRow, ToolRun } from './messages';
import { CommandState } from './command-state';

const FIRST_PAGE = 80;
const MORE = 200;

export function SharePage({ slug, token }: { slug: string; token: string | null }) {
  const [limit, setLimit] = useState(FIRST_PAGE);
  const data = useQuery(api.share.view, { slug, limit, ...(token ? { token } : {}) });
  // Keeps the last page on screen while a bigger one loads.
  const [shown, setShown] = useState<typeof data>(undefined);
  useEffect(() => {
    if (data) setShown(data);
  }, [data]);

  const title = shown?.state === 'ok' ? shown.title || 'Untitled' : undefined;
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
  return <SharedThread slug={slug} token={token} data={shown} loading={data !== shown} onMore={() => setLimit((n) => n + MORE)} />;
}

type Shared = Extract<NonNullable<ReturnType<typeof useQuery<typeof api.share.view>>>, { state: 'ok' }>;

function SharedThread({ slug, token, data, loading, onMore }: { slug: string; token: string | null; data: Shared; loading: boolean; onMore: () => void }) {
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

  const inText = useMemo(() => new Map(data.images.filter((p) => p.src).map((p) => [p.src!, p.url])), [data.images]);
  const after = useMemo(() => picturesByRow(data.messages, data.images), [data.messages, data.images]);
  const picturesFor = (seqs: number[]) => seqs.flatMap((s) => after.get(s) ?? []);

  return (
    <article className="thread shared">
      <header className="thread-head">
        <img src="/icon.png" alt="" width={26} height={26} />
        <div className="head-text">
          <h1>{data.title || 'Untitled'}</h1>
        </div>
        {data.manage && token ? (
          <div className="head-actions">
            <ShareControl token={token} threadId={data.manage.threadId} share={{ access: data.manage.shared ? 'link' : 'off', slug }} onSharePage />
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
            <div key={g.items[0]!.seq}>
              <ToolRun items={g.items} />
              <Pictures items={picturesFor(g.items.map((m) => m.seq))} />
            </div>
          ) : (
            <div key={g.m.seq} className={`msg ${g.m.role}`}>
              <MessageText text={g.m.text} pictures={inText} seq={g.m.seq} rows={data.messages} />
              <Pictures items={picturesFor([g.m.seq])} />
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

// Mike's sharing controls, on his own thread page and on the shared page
// when he's signed in: share by link, copy it, stop sharing, or a new link.
// Each is a command the runner applies (phone:share), so it shows "Waiting
// for the Mac" while the Mac is asleep. No New link on the shared page
// itself: its own address would stop working under him.
export function ShareControl({ token, threadId, share, onSharePage }: { token: string; threadId: string; share?: { access: string; slug: string }; onSharePage?: boolean }) {
  const send = useMutation(api.phone.share);
  const [pending, setPending] = useState<Id<'commands'> | null>(null);
  const [copied, setCopied] = useState(false);
  const shared = share?.access === 'link';
  const link = share ? `${location.origin}/s/${share.slug}` : undefined;
  const run = async (access: 'off' | 'link', newLink?: boolean) => setPending(await send({ token, threadId, access, ...(newLink ? { newLink: true } : {}) }));
  return (
    <details className="share-menu">
      <summary className={shared ? 'on' : ''}>{shared ? 'Shared' : 'Share'}</summary>
      <div className="share-panel">
        <p className="muted small">{shared ? 'Anyone with the link can read this thread, as it carries on.' : 'Only you can see this thread.'}</p>
        {shared && link ? (
          <div className="share-link">
            <input readOnly value={link} onFocus={(e) => e.target.select()} aria-label="Link" />
            <button
              onClick={async () => {
                await navigator.clipboard.writeText(link);
                setCopied(true);
                setTimeout(() => setCopied(false), 1500);
              }}
            >
              {copied ? 'Copied' : 'Copy'}
            </button>
          </div>
        ) : null}
        <div className="buttons">
          {shared ? (
            <>
              <button disabled={pending !== null} onClick={() => run('off')}>
                Stop sharing
              </button>
              {onSharePage ? null : (
                <button disabled={pending !== null} onClick={() => run('link', true)} title="The old link stops working">
                  New link
                </button>
              )}
            </>
          ) : (
            <button className="primary" disabled={pending !== null} onClick={() => run('link')}>
              Share with a link
            </button>
          )}
        </div>
        {pending ? <CommandState token={token} commandId={pending} onDone={() => setPending(null)} /> : null}
      </div>
    </details>
  );
}
