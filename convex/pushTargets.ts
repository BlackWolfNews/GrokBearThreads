// Which registered phones still get pushes: only those whose phone token is
// still good. Revoking a phone used to stop it reading the mirror but not
// its pushes, which carry a thread's title and the start of its text
// (pushText.ts). Plain TypeScript with no Convex imports, so the runner's
// unit tests can check it.

export type DeviceLink = { tokenId?: string; tokenName: string };
export type TokenState = { _id: string; name: string; expiresAt: number; revokedAt?: number };

// The same test as lib.ts checkPhoneToken.
const live = (t: TokenState, now: number) => !t.revokedAt && t.expiresAt >= now;

// A row registered since 5 Nov 2026 has its token's id and follows that
// token. An older one only has the token's name, so it counts while some
// live token has that name: a phone re-paired under the same name keeps
// its pushes, and one whose name has no live token left gets none.
export function hasLiveToken(device: DeviceLink, tokens: TokenState[], now: number): boolean {
  if (device.tokenId) return tokens.some((t) => t._id === device.tokenId && live(t, now));
  return tokens.some((t) => t.name === device.tokenName && live(t, now));
}

// The rows to delete once `revoked` is revoked (`tokens` already says so):
// the ones registered with it, and older name-only rows of its name that
// no live token covers any more.
export function tiedToRevoked(device: DeviceLink, revoked: { _id: string; name: string }, tokens: TokenState[], now: number): boolean {
  if (device.tokenId) return device.tokenId === revoked._id;
  return device.tokenName === revoked.name && !hasLiveToken(device, tokens, now);
}
