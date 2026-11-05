// [Picture N] in Mike's own message stands for a picture he pasted
// (docs/protocol.md, "Pictures in a message"). The Mac draws it as a chip with
// the picture behind it; here there's only the chip, as a pasted picture
// doesn't leave the Mac. Done on the parsed Markdown, so a marker in code
// stays as typed. Turned into a link the `a` renderer knows by its address.
type Node = { type: string; value?: string; url?: string; children?: Node[] };

const SCHEME = 'picture:';

export function pictureNumber(url: string): number | undefined {
  const m = url.startsWith(SCHEME) ? url.slice(SCHEME.length) : '';
  return /^\d{1,3}$/.test(m) ? Number(m) : undefined;
}

// A text node's pieces, the markers as links. Picture 0 isn't one: they
// count from 1.
export function splitMarkers(text: string): Node[] {
  const out: Node[] = [];
  let at = 0;
  for (const m of text.matchAll(/\[Picture ([1-9]\d{0,2})\]/g)) {
    if (m.index > at) out.push({ type: 'text', value: text.slice(at, m.index) });
    out.push({ type: 'link', url: `${SCHEME}${m[1]}`, children: [{ type: 'text', value: m[0] }] });
    at = m.index + m[0].length;
  }
  if (at < text.length) out.push({ type: 'text', value: text.slice(at) });
  return out;
}

function walk(node: Node): void {
  // Not into a link: a chip inside a link's words would be a link in a link.
  if (!node.children || node.type === 'link') return;
  node.children = node.children.flatMap((child) => {
    if (child.type === 'text' && child.value) return splitMarkers(child.value);
    walk(child);
    return [child];
  });
}

export function remarkPictureChips() {
  return (tree: unknown) => walk(tree as Node);
}
