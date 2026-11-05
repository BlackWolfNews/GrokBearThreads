// The pointer drawn over a recorded clip (scripts/clips.mjs): the demo app is driven by script,
// so nothing on screen moves the way a hand would. This draws macOS's arrow travelling to each
// spot the script clicked or looked at, on a slightly curved path, easing in and out, with a
// small tremor and drift so it reads as a person rather than a tween. Points are the window's
// (1240 x 820); the clip is 1600 wide, so everything scales by 1600 / 1240.

const SCALE = 1600 / 1240;
// overlays/cursor.png is 56 x 80 at 2x (28 x 40 pt), its tip at (10, 10).
export const CURSOR = { w: Math.round(28 * SCALE), h: Math.round(40 * SCALE), tipX: 5 * SCALE, tipY: 5 * SCALE };
export const RING = 40;

// A small seeded random, so a clip's cursor is the same every time it's encoded.
function random(seed) {
  let s = seed >>> 0;
  return () => ((s = (s * 1664525 + 1013904223) >>> 0) / 2 ** 32);
}
const ease = (u) => (u < 0.5 ? 4 * u * u * u : 1 - (-2 * u + 2) ** 3 / 2);

/**
 * `events`: [{ t (seconds into the clip), x, y (window points), click }], in time order.
 * Returns { at(t) -> [x, y] in clip pixels, clicks: [{ t, x, y }] }.
 */
export function cursorPath(events, seed = 7) {
  const rnd = random(seed);
  const pts = events.map((e) => ({ ...e, x: e.x * SCALE, y: e.y * SCALE }));
  // Where it rests before the first move: somewhere off to the lower right of the first target.
  const first = pts[0] ?? { x: 900, y: 600 };
  const start = { x: Math.min(1500, first.x + 260 + rnd() * 120), y: Math.min(1000, first.y + 160 + rnd() * 100) };
  const moves = [];
  let from = start;
  let free = 0.2;
  for (const p of pts) {
    const dist = Math.hypot(p.x - from.x, p.y - from.y);
    const dur = Math.min(0.95, Math.max(0.35, 0.3 + dist / 1500));
    // Arrives just before the click lands, but never leaves before the last one finished.
    const end = Math.max(free + 0.15, p.t - 0.08);
    const begin = Math.max(free, end - dur);
    // A gentle curve: the control point pushed sideways by up to 12% of the distance.
    const bend = (rnd() - 0.5) * 0.24 * dist;
    const nx = -(p.y - from.y) / (dist || 1);
    const ny = (p.x - from.x) / (dist || 1);
    const c = { x: (from.x + p.x) / 2 + nx * bend, y: (from.y + p.y) / 2 + ny * bend };
    // Lands a hair off the target and settles onto it, as a hand does.
    const miss = { x: (rnd() - 0.5) * 8, y: (rnd() - 0.5) * 6 };
    moves.push({ begin, end, from, to: p, c, miss });
    from = p;
    free = Math.max(end, p.t) + 0.12;
  }
  const phase = Array.from({ length: 6 }, () => rnd() * Math.PI * 2);
  const tremor = (t) => [
    1.1 * Math.sin(2 * Math.PI * 2.7 * t + phase[0]) + 0.7 * Math.sin(2 * Math.PI * 6.3 * t + phase[1]) + 2.2 * Math.sin(2 * Math.PI * 0.45 * t + phase[2]),
    0.9 * Math.sin(2 * Math.PI * 3.1 * t + phase[3]) + 0.6 * Math.sin(2 * Math.PI * 7.1 * t + phase[4]) + 1.8 * Math.sin(2 * Math.PI * 0.38 * t + phase[5]),
  ];
  function at(t) {
    let x = start.x;
    let y = start.y;
    for (const m of moves) {
      if (t >= m.end) {
        // Settling: the small miss shrinks to nothing over a quarter of a second.
        const k = Math.max(0, 1 - (t - m.end) / 0.25);
        x = m.to.x + m.miss.x * k;
        y = m.to.y + m.miss.y * k;
      } else if (t > m.begin) {
        const u = ease((t - m.begin) / (m.end - m.begin));
        const tx = m.to.x + m.miss.x;
        const ty = m.to.y + m.miss.y;
        x = (1 - u) ** 2 * m.from.x + 2 * (1 - u) * u * m.c.x + u * u * tx;
        y = (1 - u) ** 2 * m.from.y + 2 * (1 - u) * u * m.c.y + u * u * ty;
        break;
      } else break;
    }
    const [jx, jy] = tremor(t);
    return [x + jx, y + jy];
  }
  return { at, clicks: pts.filter((p) => p.click).map((p) => ({ t: p.t, x: p.x, y: p.y })) };
}

/** ffmpeg sendcmd lines moving `overlay@cur` frame by frame, its top left at the arrow's tip. */
export function sendcmds(path, seconds, fps = 30) {
  const lines = [];
  for (let f = 0; f <= Math.ceil(seconds * fps); f++) {
    const t = f / fps;
    const [x, y] = path.at(t);
    lines.push(`${t.toFixed(3)} overlay@cur x ${Math.round(x - CURSOR.tipX)}, overlay@cur y ${Math.round(y - CURSOR.tipY)};`);
  }
  return lines.join("\n") + "\n";
}
