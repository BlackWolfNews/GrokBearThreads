// Converting, shrinking and drawing images, for pasted photos (media.ts)
// and project pictures (project-icons.ts). macOS has all of it built in:
// sips and Quick Look. A runner on Linux uses ImageMagick (`magick`, or
// `convert` on ImageMagick 6) and rsvg-convert instead, which INSTALL.md
// ("A runner on Linux") installs. Without them every call here fails the
// way a picture sips couldn't read does, so callers keep their fallbacks.
import { execFile, execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';

const MAC = process.platform === 'darwin';

export interface ConvertOptions {
  format: 'png' | 'jpeg';
  // JPEG quality, 0 to 100.
  quality?: number;
  // Shrinks the picture to fit this many pixels on its longer side.
  maxPx?: number;
}

// The first of `names` on PATH, or undefined. Looked up once per name.
const found = new Map<string, string | undefined>();
function onPath(...names: string[]): string | undefined {
  for (const name of names) {
    if (!found.has(name)) {
      let hit: string | undefined;
      for (const dir of (process.env.PATH ?? '').split(path.delimiter)) {
        if (!dir) continue;
        const p = path.join(dir, name);
        try {
          fs.accessSync(p, fs.constants.X_OK);
          hit = p;
          break;
        } catch {
          // not here
        }
      }
      found.set(name, hit);
    }
    const hit = found.get(name);
    if (hit) return hit;
  }
  return undefined;
}

// The command that converts `src` into `out`, or undefined when this
// machine has nothing that can.
export function convertCommand(src: string, out: string, o: ConvertOptions): [string, string[]] | undefined {
  if (MAC) {
    return [
      '/usr/bin/sips',
      [
        '-s', 'format', o.format,
        ...(o.format === 'jpeg' && o.quality !== undefined ? ['-s', 'formatOptions', String(o.quality)] : []),
        ...(o.maxPx ? ['-Z', String(o.maxPx)] : []),
        src, '--out', out,
      ],
    ];
  }
  const magick = onPath('magick', 'convert');
  if (!magick) return undefined;
  return [
    magick,
    [
      // [0]: the first frame or page only, as sips does for a GIF or TIFF.
      `${src}[0]`,
      // Phone photos are often stored sideways with a turn-me tag, which
      // sips applies; ImageMagick needs telling.
      '-auto-orient',
      // ">" only ever shrinks, like -Z on the callers' already-too-big images.
      ...(o.maxPx ? ['-resize', `${o.maxPx}x${o.maxPx}>`] : []),
      ...(o.format === 'jpeg' && o.quality !== undefined ? ['-quality', String(o.quality)] : []),
      `${o.format}:${out}`,
    ],
  ];
}

// Converts `src` into `out`. Throws when it can't.
export function convertImageSync(src: string, out: string, o: ConvertOptions, timeoutMs = 30_000): void {
  const cmd = convertCommand(src, out, o);
  if (!cmd) throw new Error('No image converter on this machine (sips, or ImageMagick on Linux)');
  execFileSync(cmd[0], cmd[1], { stdio: 'ignore', timeout: timeoutMs });
}

// convertImageSync without blocking: true when `out` was made.
export function convertImage(src: string, out: string, o: ConvertOptions, timeoutMs = 20_000): Promise<boolean> {
  const cmd = convertCommand(src, out, o);
  if (!cmd) return Promise.resolve(false);
  return new Promise((resolve) => execFile(cmd[0], cmd[1], { timeout: timeoutMs }, (err) => resolve(!err && fs.existsSync(out))));
}

// Draws an SVG to a PNG at `out`, fitting `px` square. Quick Look on macOS,
// which names its own output, so the file is moved to `out`; rsvg-convert,
// else ImageMagick, on Linux. True when `out` was made.
export async function svgToPng(src: string, out: string, px: number, timeoutMs = 20_000): Promise<boolean> {
  const run = (cmd: string, args: string[]) =>
    new Promise<boolean>((resolve) => execFile(cmd, args, { timeout: timeoutMs }, (err) => resolve(!err)));
  if (MAC) {
    const dir = path.dirname(out);
    if (!(await run('/usr/bin/qlmanage', ['-t', '-s', String(px), '-o', dir, src]))) return false;
    const made = path.join(dir, path.basename(src) + '.png');
    if (!fs.existsSync(made)) return false;
    if (made !== out) await fs.promises.rename(made, out);
    return true;
  }
  const rsvg = onPath('rsvg-convert');
  if (rsvg) return (await run(rsvg, ['-w', String(px), '-h', String(px), '--keep-aspect-ratio', '-o', out, src])) && fs.existsSync(out);
  const magick = onPath('magick', 'convert');
  if (magick) return (await run(magick, ['-background', 'none', '-density', '384', src, '-resize', `${px}x${px}`, `png:${out}`])) && fs.existsSync(out);
  return false;
}
