export function bridgeRequest(address) {
  const page = new URL(address);
  const match = /^\/start\/([a-f0-9]{64})$/.exec(page.pathname);
  if (page.protocol !== 'http:' || page.hostname !== '127.0.0.1' || page.username || page.password ||
      !page.port || Number(page.port) < 1024 || !match || page.search) {
    throw new Error('Open Sign in through Chrome in the Threadbear Convex panel first.');
  }
  const nonce = match[1];
  const params = new URLSearchParams(page.hash.slice(1));
  if ([...params.keys()].join() !== 'login') throw new Error('Invalid sign-in page.');
  const login = new URL(params.get('login'));
  const state = login.searchParams.get('returnTo');
  if (login.origin !== 'https://dashboard.convex.dev' || login.pathname !== '/api/auth/login' ||
      login.username || login.password || login.hash || [...login.searchParams.keys()].join() !== 'returnTo' ||
      !state?.startsWith('/') || state.startsWith('//') || state.includes('\\')) {
    throw new Error('This extension only starts Convex dashboard sign-ins.');
  }
  const destination = new URL(state, login.origin);
  if (destination.origin !== login.origin || destination.pathname.startsWith('/api/') ||
      destination.searchParams.getAll('threadbear_sign_in').join() !== nonce) {
    throw new Error('This sign-in does not match the Threadbear page.');
  }
  return { loginURL: login.href, callbackURL: `${page.origin}/finish/${nonce}` };
}

export function redirectRule(tabId, bridge) {
  if (!Number.isSafeInteger(tabId) || tabId <= 0) throw new Error('No sign-in tab.');
  return {
    id: tabId, priority: 1,
    action: { type: 'redirect', redirect: { regexSubstitution: bridge.callbackURL + '?\\1' } },
    condition: {
      regexFilter: '^https://dashboard\\.convex\\.dev/api/auth/callback\\?([^#]+)$',
      isUrlFilterCaseSensitive: true,
      tabIds: [tabId], resourceTypes: ['main_frame'],
    },
  };
}
