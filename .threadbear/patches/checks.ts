// Threadbear's own patch (docs/protocol.md, "Patches"): chips for the
// checks an agent or Mike runs most in this repo. Output lands in the
// thread's transcript.
export default {
  actions: [
    { title: "Quick check", run: "./check.sh --quick", note: "Runner typecheck and unit tests, about 15 s" },
    { title: "App check", run: "./check.sh --app", note: "App build and tests" },
    { title: "Full check", run: "./check.sh", note: "Everything, about three minutes" },
    { title: "Runner status", run: "runner/bin/tb status" },
    { title: "Releases", run: "runner/scripts/deploy-runner.sh --list" },
  ],
  hooks: [
    // After a turn that touched the runner's TypeScript: a few seconds, and
    // the agent hears about a type error before it moves on.
    { title: "Runner typecheck", on: "turn.end", run: "cd runner && npx tsc --noEmit -p .", edited: "runner/src/**/*.ts" },
  ],
};
