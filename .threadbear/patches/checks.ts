// Threadbear's own patch (docs/protocol.md, "Patches"): chips for the
// checks an agent or Mike runs most in this repo. Output lands in the
// thread's transcript.
export default {
  // A worktree per thread (docs/thread-worktrees.md): each new thread in
  // this repo works on a thread/<id8> branch in its own worktree, and
  // `tb land` puts it on main once the quick check passes. Setup links
  // node_modules to the main checkout's (see worktree-setup.sh).
  worktree: {
    setup: "./worktree-setup.sh",
    check: "./check.sh --quick",
  },
  actions: [
    { title: "Quick check", run: "./check.sh --quick", note: "Runner typecheck and unit tests, about 15 s" },
    { title: "App check", run: "./check.sh --app", note: "App build and tests" },
    { title: "Full check", run: "./check.sh", note: "Everything, about three minutes" },
    { title: "Runner status", run: "runner/bin/tb status" },
    { title: "Releases", run: "runner/scripts/deploy-runner.sh --list" },
  ],
  panels: [
    // Several threads work on this repo at once, each in its own worktree:
    // which ones have work that isn't on main yet, and which are dirty.
    {
      title: "Worktrees",
      icon: "arrow.triangle.branch",
      items: async ({ sh }) => {
        const out = await sh(`git worktree list --porcelain | awk '/^worktree /{print $2}' | while read -r dir; do
          [ -d "$dir" ] || continue
          branch=$(git -C "$dir" branch --show-current); [ -n "$branch" ] || branch="detached"
          ahead=$(git -C "$dir" rev-list --count main..HEAD 2>/dev/null || echo 0)
          dirty=$(git -C "$dir" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
          printf '%s\t%s\t%s\t%s\n' "$dir" "$branch" "$ahead" "$dirty"
        done`);
        return out.trim().split("\n").filter(Boolean).map((line) => {
          const [dir, branch, ahead, dirty] = line.split("\t");
          const bits = [branch, Number(ahead) ? `${ahead} ahead of main` : "nothing ahead of main"];
          if (Number(dirty)) bits.push(`${dirty} uncommitted`);
          return {
            title: dir.split("/").slice(-2).join("/"),
            detail: bits.join(" · "),
            icon: "folder",
            tone: Number(dirty) ? "attention" : Number(ahead) ? undefined : "done",
          };
        });
      },
    },
  ],
  hooks: [
    // After a turn that touched the runner's TypeScript: a few seconds, and
    // the agent hears about a type error before it moves on.
    { title: "Runner typecheck", on: "turn.end", run: "cd runner && npx tsc --noEmit -p .", edited: "runner/src/**/*.ts" },
  ],
};
