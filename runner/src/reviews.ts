// Validation and text for durable image reviews. Files are copied only after
// every input has passed validation, so a bad final option leaves no card.
import fs from 'node:fs';
import path from 'node:path';
import { expandHome } from './config.ts';
import { readImageInfo } from './media.ts';
import type { DesignReview, ReviewDraft } from './protocol.ts';
import { ErrorCode, RpcError } from './protocol.ts';

// An option's pictures: `path` and then `shots`, or `shots` alone. One option
// often has several (its overview, mid-drag, a detail), which agents used to
// pass as options of their own, A2 and A3, that couldn't be picked (Mike, 4 Nov).
export type ReviewShotInput = { path: string; title?: string };
export type ReviewInput = { title: string; note?: string; options: { id: string; title: string; path?: string; shots?: ReviewShotInput[]; url?: string; note?: string; reference?: boolean }[] };
// What createReview copies: every source file, first shot first.
export type ReviewOptionSource = { id: string; title: string; note?: string; reference?: boolean; url?: string; shots: ReviewShotInput[] };
export const maxReviewShots = 8;
export const maxReviewImages = 40;

function bad(message: string): never {
  throw new RpcError(ErrorCode.badParams, message);
}

function text(v: unknown, name: string, max: number, required = false): string | undefined {
  if (v === undefined && !required) return undefined;
  if (typeof v !== 'string' || v.length > max || (required && !v.trim())) bad(`${name} must be ${required ? 'nonempty text' : 'text'} of at most ${max} characters.`);
  return (v as string).trim();
}

function imageFile(raw: unknown, cwd: string): string {
  const file = path.resolve(cwd, expandHome(text(raw, 'image path', 8192, true)!));
  try {
    const st = fs.statSync(file);
    if (!st.isFile() || st.size > 25 * 1024 * 1024) bad(`Image must be a regular file of at most 25 MB: ${file}`);
  } catch (e) {
    if (e instanceof RpcError) throw e;
    bad(`Image not found: ${file}`);
  }
  const info = readImageInfo(file);
  if (!info?.width || !info.height) bad(`Not a supported image with readable dimensions: ${file}`);
  return file;
}

export function reviewInput(raw: unknown, cwd: string): { title: string; note?: string; options: ReviewOptionSource[] } {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return bad('A review needs a title and options.');
  const p = raw as Record<string, unknown>;
  const title = text(p.title, 'title', 200, true)!;
  const note = text(p.note, 'note', 4000);
  if (!Array.isArray(p.options) || !p.options.length || p.options.length > 12) return bad('A review needs between 1 and 12 options.');
  const ids = new Set<string>();
  let images = 0;
  const options = p.options.map((raw, i) => {
    if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return bad(`options[${i}] must be an object.`);
    const o = raw as Record<string, unknown>;
    const id = text(o.id, 'option id', 200, true)!;
    if (ids.has(id)) bad(`Duplicate option id: ${id}`);
    ids.add(id);
    const title = text(o.title, 'option title', 200, true)!;
    const note = text(o.note, 'option note', 4000);
    if (o.reference !== undefined && typeof o.reference !== 'boolean') bad('reference must be a boolean.');
    const url = text(o.url, 'url', 2000);
    if (url && !/^https?:\/\/\S+$/i.test(url)) bad(`url must be an http or https address: ${url}`);
    if (o.shots !== undefined && !Array.isArray(o.shots)) bad(`shots on ${id} must be a list.`);
    const shots: ReviewShotInput[] = [];
    if (o.path !== undefined) shots.push({ path: imageFile(o.path, cwd) });
    for (const [j, s] of ((o.shots as unknown[] | undefined) ?? []).entries()) {
      if (!s || typeof s !== 'object' || Array.isArray(s)) bad(`shots[${j}] on ${id} must be an object with a path.`);
      const shot = s as Record<string, unknown>;
      const shotTitle = text(shot.title, 'shot title', 200);
      shots.push({ path: imageFile(shot.path, cwd), ...(shotTitle ? { title: shotTitle } : {}) });
    }
    if (!shots.length) bad(`Option ${id} needs an image: a path or shots.`);
    if (shots.length > maxReviewShots) bad(`Option ${id} has ${shots.length} images; at most ${maxReviewShots}.`);
    images += shots.length;
    return { id, title, shots, ...(note ? { note } : {}), ...(o.reference === true ? { reference: true } : {}), ...(url ? { url } : {}) };
  });
  if (images > maxReviewImages) bad(`A review can have at most ${maxReviewImages} images in all; this has ${images}.`);
  return { title, ...(note ? { note } : {}), options };
}

export function reviewDraft(review: DesignReview, raw: unknown, answer = false): ReviewDraft {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return bad('draft must contain notes and optional picks.');
  const d = raw as Record<string, unknown>;
  if (!d.notes || typeof d.notes !== 'object' || Array.isArray(d.notes)) return bad('notes must be an object keyed by option ID.');
  if (d.pickedId !== undefined && typeof d.pickedId !== 'string') bad('pickedId must be an option ID.');
  if (d.pickedIds !== undefined && (!Array.isArray(d.pickedIds) || d.pickedIds.some(id => typeof id !== 'string'))) bad('pickedIds must be a list of option IDs.');
  if (d.none !== undefined && typeof d.none !== 'boolean') bad('none must be a boolean.');
  // pickedIds wins; a client from before it sends pickedId alone.
  const wanted = new Set((d.pickedIds as string[] | undefined) ?? (d.pickedId !== undefined ? [d.pickedId as string] : []));
  for (const id of wanted) {
    const option = review.options.find(o => o.id === id);
    if (!option) bad(`Unknown option: ${id}`);
    if (option.reference) bad('A reference image cannot be picked.');
  }
  // In the review's order, so the same picks always read the same.
  const picks = review.options.filter(o => wanted.has(o.id)).map(o => o.id);
  const none = d.none === true;
  if (none && picks.length) bad('Pick options or none of them, not both.');
  // Avoid prototype setters for option IDs such as __proto__.
  const notes: Record<string, string> = Object.create(null);
  for (const [id, value] of Object.entries(d.notes)) {
    if (!review.options.some(o => o.id === id)) bad(`Unknown option: ${id}`);
    if (typeof value !== 'string') bad(`Notes on ${id} must be text.`);
    const note = text(value, `Notes on ${id}`, 4000)!;
    if (note) notes[id] = note;
  }
  const reply = text(d.reply, 'reply', 8000);
  if (answer && !picks.length && !none && !reply && !Object.keys(notes).length) bad('Pick an option or write a reply.');
  return {
    // pickedIds only for more than one, so a single pick saves as it always did.
    ...(picks.length ? { pickedId: picks[0] } : {}),
    ...(picks.length > 1 ? { pickedIds: picks } : {}),
    notes: { ...notes },
    ...(reply ? { reply } : {}),
    ...(none ? { none: true as const } : {}),
  };
}

export function sameDraft(a: ReviewDraft | undefined, b: ReviewDraft): boolean {
  if (!a || a.pickedId !== b.pickedId || (a.pickedIds ?? []).join('\n') !== (b.pickedIds ?? []).join('\n')) return false;
  if ((a.reply ?? '') !== (b.reply ?? '') || !!a.none !== !!b.none) return false;
  const ids = Object.keys(a.notes);
  return ids.length === Object.keys(b.notes).length && ids.every(id => a.notes[id] === b.notes[id]);
}

// What the agent reads. "Picked A." with one, "Picked A + D." with more, as
// the window's Send button says. The Mac and the phone read it back
// (ReviewAnswer) for Mike's bubble, so change them with it.
export function reviewReply(review: DesignReview, draft: ReviewDraft): string {
  const lines = [`Review: ${review.title} (${review.id})`];
  const picks = draft.pickedIds ?? (draft.pickedId ? [draft.pickedId] : []);
  if (picks.length) lines.push(`Picked ${picks.join(' + ')}. ${picks.map(id => review.options.find(o => o.id === id)!.title).join(' + ')}.`);
  if (draft.none) lines.push('Picked none of them.');
  if (draft.reply) lines.push(draft.reply);
  for (const o of review.options) if (Object.hasOwn(draft.notes, o.id) && draft.notes[o.id]) lines.push(`Notes on ${o.id} (${o.title}): ${draft.notes[o.id]}`);
  return lines.join('\n\n');
}
