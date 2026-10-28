import { useEffect } from 'react';
import { useQuery } from 'convex/react';
import { api } from '../../convex/_generated/api';
import type { Id } from '../../convex/_generated/dataModel';

// What happened to the last thing sent: the runner takes a command within a
// second or two while it's online, so "waiting" for longer means the Mac is
// asleep or offline.
export function CommandState({ token, commandId, onDone }: { token: string; commandId: Id<'commands'>; onDone: () => void }) {
  const c = useQuery(api.phone.command, { token, commandId });
  useEffect(() => {
    if (c?.state !== 'done') return;
    const t = setTimeout(onDone, 1200);
    return () => clearTimeout(t);
  }, [c?.state, onDone]);
  if (!c || c.state === 'done') return null;
  return (
    <div className={`command ${c.state}`}>
      {c.state === 'pending' ? 'Waiting for the Mac to pick this up…' : c.state === 'taken' ? 'Sent to the Mac…' : `Didn’t work: ${c.note ?? 'unknown error'}`}
      {c.state === 'failed' ? (
        <button className="link" onClick={onDone}>
          Dismiss
        </button>
      ) : null}
    </div>
  );
}
