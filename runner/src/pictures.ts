// Where a message's pictures go among its words (docs/protocol.md,
// "Pictures in a message"). `[Picture N]` stands for images[N-1], and the
// picture goes straight after the first marker naming it, so "this
// [Picture 1] next to this [Picture 2]" reaches the agent with each
// picture where Mike pasted it. Pictures no marker names go first, as
// every picture did before markers (the phone's, an ask box's).
import type { ImageRef } from './protocol.ts';

export type MessagePart = { text: string } | { image: ImageRef };

const MARKER = /\[Picture (\d{1,3})\]/g;

export function placePictures(text: string, images: ImageRef[]): MessagePart[] {
  const cuts = pictureCuts(text, images.length);
  const placed = new Set(cuts.map((c) => c.index));
  const parts: MessagePart[] = [];
  images.forEach((image, i) => {
    if (!placed.has(i)) parts.push({ image });
  });
  let from = 0;
  for (const cut of cuts) {
    pushWords(parts, text.slice(from, cut.at));
    parts.push({ image: images[cut.index] });
    from = cut.at;
  }
  pushWords(parts, text.slice(from));
  return parts;
}

// Where each of `count` pictures goes: just after the first marker naming
// it, in the order the markers come. A marker naming no picture, or one
// already placed, is just words.
function pictureCuts(text: string, count: number): { at: number; index: number }[] {
  const placed = new Set<number>();
  const cuts: { at: number; index: number }[] = [];
  for (const m of text.matchAll(MARKER)) {
    const index = Number(m[1]) - 1;
    if (index < 0 || index >= count || placed.has(index)) continue;
    placed.add(index);
    cuts.push({ at: m.index + m[0].length, index });
  }
  return cuts;
}

// How many of a message's `count` pictures no marker places: the ones that
// go before the words.
export function unplacedPictures(text: string, count: number): number {
  return count - pictureCuts(text, count).length;
}

// The Claude API turns down a text block of nothing but whitespace, as
// between two pictures pasted one after the other.
function pushWords(parts: MessagePart[], text: string): void {
  if (text.trim()) parts.push({ text });
}
