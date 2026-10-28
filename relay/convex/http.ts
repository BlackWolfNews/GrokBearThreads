// The relay's whole API (docs/push-relay.md):
//
//   POST /register  { version? }  ->  { installId, installKey }
//     Once per Threadbear backend, which keeps the pair in its env.
//
//   POST /send  Authorization: Bearer <installId>.<installKey>
//     { deviceToken, environment: "sandbox" | "production", threadId,
//       encrypted?: base64 AES-GCM sealed box, or title?/body? }
//     ->  { ok, status, reason?, gone? }  (gone: drop this device token)
//
// Nothing here is stored but the install row and daily counts.
import { httpRouter } from 'convex/server';
import { httpAction } from './_generated/server';
import { internal } from './_generated/api';

const http = httpRouter();

const json = (value: unknown, status = 200) => new Response(JSON.stringify(value), { status, headers: { 'Content-Type': 'application/json' } });

async function body(req: Request): Promise<Record<string, unknown> | null> {
  try {
    const text = await req.text();
    if (text.length > 16_000) return null;
    const v = text ? JSON.parse(text) : {};
    return v && typeof v === 'object' ? (v as Record<string, unknown>) : null;
  } catch {
    return null;
  }
}

const str = (v: unknown, max: number) => (typeof v === 'string' && v.length > 0 && v.length <= max ? v : undefined);

http.route({
  path: '/register',
  method: 'POST',
  handler: httpAction(async (ctx, req) => {
    const b = await body(req);
    if (!b) return json({ error: 'bad request' }, 400);
    try {
      return json(await ctx.runMutation(internal.relay.register, { ...(str(b.version, 40) ? { version: str(b.version, 40) } : {}) }));
    } catch {
      return json({ error: 'too many new installs today' }, 429);
    }
  }),
});

http.route({
  path: '/send',
  method: 'POST',
  handler: httpAction(async (ctx, req) => {
    const auth = req.headers.get('authorization')?.match(/^Bearer (i_[0-9a-f]+)\.(k_[0-9a-f]+)$/);
    if (!auth) return json({ error: 'unauthorized' }, 401);
    const b = await body(req);
    const deviceToken = str(b?.deviceToken, 200);
    const environment = b?.environment === 'production' ? 'production' : b?.environment === 'sandbox' ? 'sandbox' : undefined;
    const threadId = str(b?.threadId, 100);
    if (!b || !deviceToken || !/^[0-9a-f]+$/i.test(deviceToken) || !environment || !threadId) return json({ error: 'bad request' }, 400);
    const version = str(req.headers.get('x-threadbear-version'), 40);
    const admitted = await ctx.runMutation(internal.relay.admit, { installId: auth[1]!, installKey: auth[2]!, ...(version ? { version } : {}) });
    if (admitted === 'auth') return json({ error: 'unauthorized' }, 401);
    if (admitted === 'limited') return json({ error: 'rate limited' }, 429);
    const encrypted = str(b.encrypted, 4000);
    const r = await ctx.runAction(internal.apns.send, {
      deviceToken,
      environment,
      threadId,
      ...(encrypted ? { encrypted } : { ...(str(b.title, 200) ? { title: str(b.title, 200) } : {}), ...(str(b.body, 1000) ? { body: str(b.body, 1000) } : {}) }),
    });
    const ok = r.status === 200;
    await ctx.runMutation(internal.relay.counted, { ok });
    const gone = r.status === 410 || r.reason === 'BadDeviceToken' || r.reason === 'Unregistered';
    return json({ ok, status: r.status, ...(r.reason ? { reason: r.reason } : {}), ...(gone ? { gone: true } : {}) });
  }),
});

http.route({ path: '/health', method: 'GET', handler: httpAction(async () => json({ ok: true })) });

export default http;
