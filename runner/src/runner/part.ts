// A part of the Runner as runner.ts merges it into the class's type: its
// methods without their `this: Runner` parameter, so they can be called
// through a Pick<Runner, ...> like the class's own methods.
export type RunnerPart<T> = { [K in keyof T]: OmitThisParameter<T[K]> };
