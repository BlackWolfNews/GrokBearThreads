// The icons a Pocket card can have. The phone gives each its symbol and
// colour (PocketIcon in ios/ThreadbearKit), so the same kind of card always
// looks the same, and one it doesn't know yet just gets its plain default.
export const POCKET_ICONS = ['plane', 'parcel', 'shopping', 'tools', 'food', 'car', 'health', 'ticket', 'money', 'home'] as const;
export type PocketIconName = (typeof POCKET_ICONS)[number];
