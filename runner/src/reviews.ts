// Validation and text for durable image reviews. Files are copied only after
// every input has passed validation, so a bad final option leaves no card.
import fs from 'node:fs';
import path from 'node:path';
import { expandHome } from './config.ts';
import { readImageInfo } from './media.ts';
import type { DesignReview, ReviewDraft } from './protocol.ts';
import { ErrorCode, RpcError } from './protocol.ts';

export type ReviewInput = { title: string; note?: string; options: { id: string; title: string; path: string; note?: string; reference?: boolean }[] };
function bad(message: string): never {
  throw new RpcError(ErrorCode.badParams, message);
}

function text(v: unknown, name: string, max: number, required = false): string | undefined {
  if (v === undefined && !required) return undefined;
  if (typeof v !== 'string' || v.length > max || (required && !v.trim())) bad(`${name} must be ${required ? 'nonempty text' : 'text'} of at most ${max} characters.`);
  return (v as string).trim();
}

export function reviewInput(raw: unknown, cwd: string): ReviewInput {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return bad('A review needs a title and options.');
  const p = raw as Record<string, unknown>;
  const title = text(p.title, 'title', 200, true)!;
  const note = text(p.note, 'note', 4000);
  if (!Array.isArray(p.options) || !p.options.length || p.options.length > 12) return bad('A review needs between 1 and 12 images.');
  const ids = new Set<string>();
  const options = p.options.map((raw, i) => {
    if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return bad(`options[${i}] must be an object.`);
    const o = raw as Record<string, unknown>;
    const id = text(o.id, 'option id', 200, true)!;
    if (ids.has(id)) bad(`Duplicate option id: ${id}`);
    ids.add(id);
    const title = text(o.title, 'option title', 200, true)!;
    const note = text(o.note, 'option note', 4000);
    if (o.reference !== undefined && typeof o.reference !== 'boolean') bad('reference must be a boolean.');
    const file = path.resolve(cwd, expandHome(text(o.path, 'image path', 8192, true)!));
    try {
      const st = fs.statSync(file);
      if (!st.isFile() || st.size > 25 * 1024 * 1024) bad(`Image must be a regular file of at most 25 MB: ${file}`);
    } catch (e) {
      if (e instanceof RpcError) throw e;
      bad(`Image not found: ${file}`);
    }
    const info = readImageInfo(file);
    if (!info?.width || !info.height) bad(`Not a supported image with readable dimensions: ${file}`);
    return { id, title, path: file, ...(note ? { note } : {}), ...(o.reference === true ? { reference: true } : {}) };
  });
  return { title, ...(note ? { note } : {}), options };
}

export function reviewDraft(review: DesignReview, raw: unknown, answer = false): ReviewDraft {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return bad('draft must contain notes and an optional pickedId.');
  const d = raw as Record<string, unknown>;
  if (!d.notes || typeof d.notes !== 'object' || Array.isArray(d.notes)) return bad('notes must be an object keyed by option ID.');
  if (d.pickedId !== undefined && typeof d.pickedId !== 'string') bad('pickedId must be an option ID.');
  const pickedId = d.pickedId as string | undefined;
  if (pickedId !== undefined) {
    const option = review.options.find(o => o.id === pickedId);
    if (!option) return bad(`Unknown option: ${ pickedId }`);
    if (option.reference) bad('A reference image cannot be picked.');
  }
  // Avoid prototype setters for option IDs such as __proto__.
  const notes: Record<string, string> = Object.create(null);
  for (const [id, value] of Object.entries(d.notes)) {
    if (!review.options.some(o => o.id === id)) bad(`Unknown option: ${id}`);
    if (typeof value !== 'string') bad(`Notes on ${id} must be text.`);
    const note = text(value, `Notes on ${id}`, 4000)!;
    if (note) notes[id] = note;
  }
  if (answer && pickedId === undefined && !Object.keys(notes).length) bad('Pick an option or leave at least one note.');
  return { ...(pickedId !== undefined ? { pickedId } : {}), notes: { ...notes } };
}

export function sameDraft(a: ReviewDraft | undefined, b: ReviewDraft): boolean {
  if (!a || a.pickedId !== b.pickedId) return false;
  const ids = Object.keys(a.notes);
  return ids.length === Object.keys(b.notes).length && ids.every(id => a.notes[id] === b.notes[id]);
}

export function reviewReply(review: DesignReview, draft: ReviewDraft): string {
  const lines = [`Review: ${review.title} (${review.id})`];
  if (draft.pickedId) lines.push(`Picked ${draft.pickedId}. ${review.options.find(o => o.id === draft.pickedId)!.title}.`);
  for (const o of review.options) if (Object.hasOwn(draft.notes, o.id) && draft.notes[o.id]) lines.push(`Notes on ${o.id} (${o.title}): ${draft.notes[o.id]}`);
  return lines.join('\n\n');
}
