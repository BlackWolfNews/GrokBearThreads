"use node";
// Push notifications when a thread needs Mike: APNs over HTTP/2 with the
// team's token-based (ES256) auth key, the way poddle/convex/apns.ts does
// it. Env on the deployment: APNS_KEY_P8 (the .p8 contents), APNS_KEY_ID,
// APNS_TEAM_ID, APNS_TOPIC (the phone app's bundle id). Without them
// every send is a logged no-op. Each device row says whether it's a
// sandbox (Xcode) or production (TestFlight, App Store) install, and
// goes to the matching APNs host.
import { createPrivateKey, sign } from 'node:crypto';
import http2 from 'node:http2';
import { v } from 'convex/values';
import { internal } from './_generated/api';
import { internalAction, type ActionCtx } from './_generated/server';
import { pushText } from './pushText';

type ApnsConfig = { key: string; keyId: string; teamId: string; topic: string };

function apnsConfig(): ApnsConfig | null {
  const { APNS_KEY_P8, APNS_KEY_ID, APNS_TEAM_ID, APNS_TOPIC } = process.env;
  if (!APNS_KEY_P8 || !APNS_KEY_ID || !APNS_TEAM_ID || !APNS_TOPIC) return null;
  return { key: toPem(APNS_KEY_P8), keyId: APNS_KEY_ID, teamId: APNS_TEAM_ID, topic: APNS_TOPIC };
}

function toPem(raw: string): string {
  const s = raw.replace(/\\n/g, '\n').trim();
  if (s.includes('BEGIN PRIVATE KEY')) return s;
  const body = s.replace(/\s+/g, '').match(/.{1,64}/g)?.join('\n') ?? '';
  return `-----BEGIN PRIVATE KEY-----\n${body}\n-----END PRIVATE KEY-----`;
}

const b64url = (b: Buffer | string) => Buffer.from(b).toString('base64url');

let cachedJwt: { token: string; issuedAt: number; keyId: string } | null = null;

// Apple wants the provider token refreshed at most every 20 minutes and
// at least hourly.
function providerToken(cfg: ApnsConfig, nowMs = Date.now()): string {
  if (cachedJwt && cachedJwt.keyId === cfg.keyId && nowMs - cachedJwt.issuedAt < 50 * 60_000) return cachedJwt.token;
  const iat = Math.floor(nowMs / 1000);
  const input = `${b64url(JSON.stringify({ alg: 'ES256', kid: cfg.keyId }))}.${b64url(JSON.stringify({ iss: cfg.teamId, iat }))}`;
  const signature = sign('sha256', Buffer.from(input), { key: createPrivateKey(cfg.key), dsaEncoding: 'ieee-p1363' });
  const token = `${input}.${b64url(signature)}`;
  cachedJwt = { token, issuedAt: nowMs, keyId: cfg.keyId };
  return token;
}

type SendResult = { token: string; status: number; reason?: string };

function sendOne(session: http2.ClientHttp2Session, cfg: ApnsConfig, jwt: string, token: string, payload: string): Promise<SendResult> {
  return new Promise((resolve) => {
    const req = session.request({
      ':method': 'POST',
      ':path': `/3/device/${token}`,
      authorization: `bearer ${jwt}`,
      'apns-topic': cfg.topic,
      'apns-push-type': 'alert',
      'apns-priority': '10',
      'content-type': 'application/json',
    });
    let status = 0;
    let body = '';
    req.setEncoding('utf8');
    req.on('response', (headers) => (status = Number(headers[':status'] ?? 0)));
    req.on('data', (chunk: string) => (body += chunk));
    req.on('end', () => {
      let reason: string | undefined;
      try {
        reason = body ? (JSON.parse(body) as { reason?: string }).reason : undefined;
      } catch {
        reason = body || undefined;
      }
      resolve({ token, status, reason });
    });
    req.on('error', (e) => resolve({ token, status: 0, reason: e.message }));
    req.setTimeout(10_000, () => {
      req.close();
      resolve({ token, status: 0, reason: 'timeout' });
    });
    req.end(payload);
  });
}

type SendSummary = { sent: number; failed: number; skipped?: string };
const vSendResult = v.object({ sent: v.number(), failed: v.number(), skipped: v.optional(v.string()) });

// The payload the phone app expects (docs/convex-backend.md, section 6).
async function sendAlert(ctx: ActionCtx, alert: { title: string; body: string; threadId: string }): Promise<SendSummary> {
  const cfg = apnsConfig();
  if (!cfg) {
    console.log(`[apns] not configured, skipping: ${alert.title}`);
    return { sent: 0, failed: 0, skipped: 'unconfigured' };
  }
  const targets: { apnsToken: string; environment: 'sandbox' | 'production' }[] = await ctx.runQuery(internal.devices.targets, {});
  if (!targets.length) return { sent: 0, failed: 0, skipped: 'noDevices' };
  const payload = JSON.stringify({ aps: { alert: { title: alert.title, body: alert.body }, sound: 'default', 'thread-id': alert.threadId }, threadId: alert.threadId });
  const jwt = providerToken(cfg);
  let sent = 0;
  let failed = 0;
  for (const env of ['sandbox', 'production'] as const) {
    const tokens = targets.filter((t) => t.environment === env).map((t) => t.apnsToken);
    if (!tokens.length) continue;
    const host = env === 'production' ? 'https://api.push.apple.com' : 'https://api.sandbox.push.apple.com';
    const session = http2.connect(host);
    session.on('error', (e) => console.error(`[apns] session error: ${e.message}`));
    try {
      const results = await Promise.all(tokens.map((t) => sendOne(session, cfg, jwt, t, payload)));
      for (const r of results) {
        if (r.status === 200) sent++;
        else {
          failed++;
          console.warn(`[apns] ${r.status} ${r.reason ?? ''} for …${r.token.slice(-6)}`);
          if (r.status === 410 || r.reason === 'BadDeviceToken' || r.reason === 'Unregistered') {
            await ctx.runMutation(internal.devices.drop, { apnsToken: r.token });
          }
        }
      }
    } finally {
      session.close();
    }
  }
  return { sent, failed };
}

// Scheduled by sync:upsertThreads when a thread starts needing Mike.
export const notify = internalAction({
  args: { threadId: v.string() },
  returns: vSendResult,
  handler: async (ctx, { threadId }): Promise<SendSummary> => {
    const t: { title: string; status: string; preview: string; pendingApproval?: any; needsYou: boolean } | null = await ctx.runQuery(internal.devices.threadForPush, { threadId });
    // It may have been seen on the Mac in the meantime.
    if (!t || !t.needsYou) return { sent: 0, failed: 0, skipped: 'noLongerNeedsYou' };
    return await sendAlert(ctx, { ...pushText(t), threadId });
  },
});

// A test to every registered phone:
//   npx convex run push:test '{"body":"hello from Convex"}' --prod
export const test = internalAction({
  args: { title: v.optional(v.string()), body: v.optional(v.string()) },
  returns: vSendResult,
  handler: async (ctx, { title, body }): Promise<SendSummary> => await sendAlert(ctx, { title: title ?? 'Threadbear', body: body ?? 'Test notification', threadId: 'test' }),
});
