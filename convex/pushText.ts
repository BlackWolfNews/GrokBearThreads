// What a push says for a thread that needs Mike: the thread's title, and
// a line about why. Plain TypeScript with no Convex imports, so the
// runner's unit tests can check it.

export type PushThread = {
  title: string;
  mac?: string; // a runner key's Mac (devices.ts threadForPush): named in the title
  status: string;
  preview: string;
  pendingApproval?:
    | { kind: 'approval'; name: string; title: string; inputSummary?: string }
    | { kind: 'question'; questions: { question: string }[] }
    | { kind: 'secret'; label: string };
};

export const PUSH_BODY_CHARS = 180;

export function pushText(t: PushThread): { title: string; body: string } {
  // A thread on a Mac with a runner key says which, so a push asking for a
  // secret or an approval can't pass for one from the main Mac.
  const title = t.mac ? `${t.mac} · ${t.title || 'Threadbear'}` : t.title || 'Threadbear';
  const p = t.pendingApproval;
  let body: string;
  if (p?.kind === 'question') body = p.questions[0]?.question ?? 'Has a question for you';
  else if (p?.kind === 'secret') body = `Asking for a secret: ${p.label}`;
  else if (p?.kind === 'approval') body = p.inputSummary ? `${p.title}: ${p.inputSummary}` : p.title;
  else if (t.status === 'error') body = t.preview ? `Failed: ${t.preview}` : 'The last turn failed';
  else body = t.preview || 'Finished';
  body = body.replace(/\s+/g, ' ').trim();
  if (body.length > PUSH_BODY_CHARS) body = body.slice(0, PUSH_BODY_CHARS - 1) + '…';
  return { title, body };
}
