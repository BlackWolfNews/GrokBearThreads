// What setup does about this Mac's backend key (scripts/setup.mjs, step 5;
// docs/protocol.md, "Runner keys"), worked out apart from doing it so a
// unit test can check it (runner/test/unit/runner-keys.test.ts). Node
// built-ins only, like setup.
//
//   envGet  `npx convex env get RUNNER_KEY`: { status, stdout, stderr }
//   nextGet `npx convex env get RUNNER_KEY_NEXT`, the same shape
//   local   what secrets/convex-key holds now ('' for nothing)
//   joining setup's --existing: a Mac joining a deployment another Mac set up
//
// Returns { action, why? }:
//   fail  stop with `why`: nothing is written and RUNNER_KEY is untouched
//   keep  secrets/convex-key is right as it is
//   copy  write the deployment's RUNNER_KEY into secrets/convex-key (the first Mac)
//   set   set RUNNER_KEY to the local key, or a new one (a deployment with none)
//   joined  this Mac has a runner key: leave it, and RUNNER_KEY, alone
// Whether this Mac joined another Mac's Threadbear: setup's --existing, or
// a runner key already in secrets/convex-key (setup run again there without
// the flag). A joining Mac gets no Convex login, deploy key or backend
// deploy from setup, and never the main key: its key comes from the first
// Mac (tb runner add).
export function isJoining({ existing, local }) {
  return Boolean(existing) || (local ?? '').startsWith('tbr_');
}

const unsetOk = (got) => got.status === 0 && !(got.stdout ?? '').trim() && /not found/i.test(got.stderr ?? '');

export function runnerKeyPlan({ envGet, nextGet, local, joining }) {
  // A joining Mac's key comes from the first Mac (tb runner add), and a
  // runner key is never overwritten with the main key, nor made the main key.
  if (joining || (local ?? '').startsWith('tbr_')) return { action: 'joined' };
  // Only a clean "not found" means the deployment has none: a failed read
  // (no network, a bad deploy key) must never look like an empty one, or a
  // Mac would set RUNNER_KEY to a key of its own and become the owner.
  if (envGet.status !== 0) return { action: 'fail', why: "Couldn't read the deployment's RUNNER_KEY (npx convex env get RUNNER_KEY failed), so setup stopped rather than guess. Check the network and the deploy key, then run setup again." };
  const value = (envGet.stdout ?? '').trim();
  const notFound = !value && /not found/i.test(envGet.stderr ?? '');
  if (!value && !notFound) return { action: 'fail', why: "npx convex env get RUNNER_KEY gave nothing back and didn't say it's unset, so setup stopped rather than guess. Run setup again." };
  if (value && local === value) return { action: 'keep' };
  // Mid-rotation (tb runner rotate-owner), secrets/convex-key holds the new
  // key and RUNNER_KEY the old: copying would put the old one back, and
  // --finish would then keep it alive. So no copy or set until it's
  // finished, nor when whether one's under way can't be told.
  if (!nextGet || !unsetOk(nextGet)) return { action: 'fail', why: (nextGet?.status === 0 && (nextGet.stdout ?? '').trim()) ? 'The main key is being rotated (RUNNER_KEY_NEXT is set): finish with tb runner rotate-owner --finish, then run setup again.' : "Couldn't tell whether the main key is being rotated (npx convex env get RUNNER_KEY_NEXT failed), so setup stopped rather than guess. Run setup again." };
  if (value) return { action: 'copy' };
  return { action: 'set' };
}
