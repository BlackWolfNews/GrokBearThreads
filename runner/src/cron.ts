// Five-field cron (minute hour day-of-month month day-of-week) read in an
// IANA time zone, for schedules. Works in wall-clock time, then turns the
// wall time into an instant, so "9:00" means 9:00 in that zone on both
// sides of a daylight-saving change.

export type CronSpec = {
  source: string;
  minutes: Set<number>;
  hours: Set<number>;
  days: Set<number>; // 1-31
  months: Set<number>; // 1-12
  weekdays: Set<number>; // 0-6, Sunday is 0
  // Restricted means not `*`: standard cron matches either day field when
  // both are restricted, and only the restricted one otherwise.
  daysRestricted: boolean;
  weekdaysRestricted: boolean;
};

const ALIASES: Record<string, string> = {
  '@hourly': '0 * * * *',
  '@daily': '0 0 * * *',
  '@midnight': '0 0 * * *',
  '@weekly': '0 0 * * 0',
  '@monthly': '0 0 1 * *',
  '@yearly': '0 0 1 1 *',
  '@annually': '0 0 1 1 *',
};

const MONTHS = ['jan', 'feb', 'mar', 'apr', 'may', 'jun', 'jul', 'aug', 'sep', 'oct', 'nov', 'dec'];
const WEEKDAYS = ['sun', 'mon', 'tue', 'wed', 'thu', 'fri', 'sat'];

export class CronError extends Error {}

function parseField(field: string, name: string, min: number, max: number, names?: string[]): Set<number> {
  const out = new Set<number>();
  const value = (s: string): number => {
    const lower = s.toLowerCase();
    if (names) {
      const i = names.indexOf(lower);
      if (i >= 0) return i + (min === 1 ? 1 : 0);
    }
    if (!/^\d+$/.test(s)) throw new CronError(`Can't read "${s}" in the ${name} field.`);
    const n = Number(s);
    // Day of week takes 7 for Sunday too.
    if (name === 'day of week' && n === 7) return 0;
    if (n < min || n > max) throw new CronError(`${name[0].toUpperCase()}${name.slice(1)} ${n} is out of range (${min}-${max}).`);
    return n;
  };
  for (const part of field.split(',')) {
    if (!part) throw new CronError(`The ${name} field has an empty item.`);
    const [range, stepText] = part.split('/');
    let step = 1;
    if (stepText !== undefined) {
      if (!/^\d+$/.test(stepText) || Number(stepText) === 0) throw new CronError(`Can't read the step "/${stepText}" in the ${name} field.`);
      step = Number(stepText);
    }
    let lo: number;
    let hi: number;
    if (range === '*') {
      lo = min;
      hi = name === 'day of week' ? 6 : max;
    } else if (range.includes('-')) {
      const [a, b] = range.split('-');
      lo = value(a);
      // "5-7" for Friday to Sunday: 7 is Sunday, the end of the week here.
      hi = name === 'day of week' && b === '7' ? 7 : value(b);
      if (hi < lo) throw new CronError(`The range ${range} in the ${name} field goes backwards.`);
    } else {
      lo = value(range);
      // "5/15" means from 5 to the end, every 15.
      hi = stepText !== undefined ? max : lo;
    }
    for (let n = lo; n <= hi; n += step) out.add(name === 'day of week' ? n % 7 : n);
  }
  return out;
}

export function parseCron(source: string): CronSpec {
  const trimmed = source.trim();
  const expanded = ALIASES[trimmed.toLowerCase()] ?? trimmed;
  const fields = expanded.split(/\s+/).filter(Boolean);
  if (fields.length !== 5) {
    throw new CronError(`A cron has 5 fields (minute hour day month weekday), and "${trimmed}" has ${fields.length}.`);
  }
  const [mi, h, d, mo, wd] = fields;
  return {
    source: trimmed,
    minutes: parseField(mi, 'minute', 0, 59),
    hours: parseField(h, 'hour', 0, 23),
    days: parseField(d, 'day of month', 1, 31),
    months: parseField(mo, 'month', 1, 12, MONTHS),
    weekdays: parseField(wd, 'day of week', 0, 7, WEEKDAYS),
    daysRestricted: d !== '*' && !d.startsWith('*/'),
    weekdaysRestricted: wd !== '*' && !wd.startsWith('*/'),
  };
}

// ------------------------------------------------------------ time zones

export function localZone(): string {
  return Intl.DateTimeFormat().resolvedOptions().timeZone || 'UTC';
}

export function checkZone(zone: string): string {
  try {
    new Intl.DateTimeFormat('en-US', { timeZone: zone });
    return zone;
  } catch {
    throw new CronError(`Unknown time zone "${zone}". Use an IANA name like Australia/Perth.`);
  }
}

type Wall = { y: number; mo: number; d: number; h: number; mi: number };

const formatters = new Map<string, Intl.DateTimeFormat>();
function formatter(zone: string): Intl.DateTimeFormat {
  let f = formatters.get(zone);
  if (!f) {
    f = new Intl.DateTimeFormat('en-US', {
      timeZone: zone,
      hourCycle: 'h23',
      year: 'numeric',
      month: 'numeric',
      day: 'numeric',
      hour: 'numeric',
      minute: 'numeric',
    });
    formatters.set(zone, f);
  }
  return f;
}

export function wallAt(ms: number, zone: string): Wall {
  const parts: Record<string, number> = {};
  for (const p of formatter(zone).formatToParts(new Date(ms))) {
    if (p.type !== 'literal') parts[p.type] = Number(p.value);
  }
  return { y: parts.year, mo: parts.month, d: parts.day, h: parts.hour, mi: parts.minute };
}

// The wall time as if it were UTC: a plain calendar number to do sums on.
const wallMs = (w: Wall): number => Date.UTC(w.y, w.mo - 1, w.d, w.h, w.mi);

// The zone's offset from UTC at an instant, in ms.
function offsetAt(ms: number, zone: string): number {
  const minute = Math.floor(ms / 60_000) * 60_000;
  return wallMs(wallAt(minute, zone)) - minute;
}

// The first instant at or after this wall time in the zone. A wall time
// skipped by a daylight-saving jump comes out as the first minute after the
// jump; one that happens twice comes out as the first of the two.
export function instantOf(w: Wall, zone: string): number {
  const target = wallMs(w);
  // Zones change offset at most once in a day, so the offsets half a day
  // either side are the only two this wall time can be in.
  const a = target - offsetAt(target - 14 * 3_600_000, zone);
  const b = target - offsetAt(target + 14 * 3_600_000, zone);
  const exact = [a, b].filter((c) => wallMs(wallAt(c, zone)) === target);
  if (exact.length) return Math.min(...exact);
  // In a gap: the jump is between the two, and wall time only goes forward
  // there, so search for the first minute at or after the target.
  let lo = Math.min(a, b);
  let hi = Math.max(a, b);
  while (hi - lo > 60_000) {
    const mid = Math.floor((lo + hi) / 2 / 60_000) * 60_000;
    if (wallMs(wallAt(mid, zone)) >= target) hi = mid;
    else lo = mid;
  }
  return hi;
}

// ------------------------------------------------------------- next runs

function daysInMonth(y: number, mo: number): number {
  return new Date(Date.UTC(y, mo, 0)).getUTCDate();
}

function dayMatches(spec: CronSpec, w: Wall): boolean {
  const dom = spec.days.has(w.d);
  const dow = spec.weekdays.has(new Date(Date.UTC(w.y, w.mo - 1, w.d)).getUTCDay());
  if (spec.daysRestricted && spec.weekdaysRestricted) return dom || dow;
  if (spec.daysRestricted) return dom;
  if (spec.weekdaysRestricted) return dow;
  return dom && dow;
}

// The first run strictly after `afterMs`, or undefined if there's none in
// the next five years (a cron for 30 February).
export function nextRun(spec: CronSpec, afterMs: number, zone: string): number | undefined {
  const start = wallAt(afterMs + 60_000, zone);
  let w: Wall = { ...start };
  const limit = start.y + 5;
  // Walk the calendar, skipping a whole month, day or hour at a time when
  // that part doesn't match.
  while (w.y <= limit) {
    if (!spec.months.has(w.mo)) {
      w = w.mo === 12 ? { y: w.y + 1, mo: 1, d: 1, h: 0, mi: 0 } : { y: w.y, mo: w.mo + 1, d: 1, h: 0, mi: 0 };
      continue;
    }
    if (w.d > daysInMonth(w.y, w.mo) || !dayMatches(spec, w)) {
      const next = new Date(Date.UTC(w.y, w.mo - 1, w.d + 1));
      w = { y: next.getUTCFullYear(), mo: next.getUTCMonth() + 1, d: next.getUTCDate(), h: 0, mi: 0 };
      continue;
    }
    if (!spec.hours.has(w.h)) {
      if (w.h === 23) {
        const next = new Date(Date.UTC(w.y, w.mo - 1, w.d + 1));
        w = { y: next.getUTCFullYear(), mo: next.getUTCMonth() + 1, d: next.getUTCDate(), h: 0, mi: 0 };
      } else w = { ...w, h: w.h + 1, mi: 0 };
      continue;
    }
    if (!spec.minutes.has(w.mi)) {
      if (w.mi === 59) {
        w = { ...w, mi: 0 };
        if (w.h === 23) {
          const next = new Date(Date.UTC(w.y, w.mo - 1, w.d + 1));
          w = { y: next.getUTCFullYear(), mo: next.getUTCMonth() + 1, d: next.getUTCDate(), h: 0, mi: 0 };
        } else w.h += 1;
      } else w = { ...w, mi: w.mi + 1 };
      continue;
    }
    const at = instantOf(w, zone);
    // A wall time that happens twice (clocks going back) has already run
    // if its first instant is behind us; and a skipped one lands after
    // the jump, which may also be behind afterMs on a second pass.
    if (at > afterMs) return at;
    w = w.mi === 59 ? { ...w, mi: 0, h: w.h + 1 } : { ...w, mi: w.mi + 1 };
    if (w.h === 24) {
      const next = new Date(Date.UTC(w.y, w.mo - 1, w.d + 1));
      w = { y: next.getUTCFullYear(), mo: next.getUTCMonth() + 1, d: next.getUTCDate(), h: 0, mi: 0 };
    }
  }
  return undefined;
}

export function nextRuns(spec: CronSpec, afterMs: number, zone: string, count: number): number[] {
  const out: number[] = [];
  let t = afterMs;
  while (out.length < count) {
    const n = nextRun(spec, t, zone);
    if (n === undefined) break;
    out.push(n);
    t = n;
  }
  return out;
}

// ----------------------------------------------------------------- words

const DAY_NAMES = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];
const MONTH_NAMES = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];

const pad = (n: number): string => String(n).padStart(2, '0');
const sorted = (s: Set<number>): number[] => [...s].sort((a, b) => a - b);

function ordinal(n: number): string {
  const s = n % 100 >= 11 && n % 100 <= 13 ? 'th' : ({ 1: 'st', 2: 'nd', 3: 'rd' } as Record<number, string>)[n % 10] ?? 'th';
  return `${n}${s}`;
}

function listWords(words: string[]): string {
  return words.length <= 1 ? words.join('') : `${words.slice(0, -1).join(', ')} and ${words.at(-1)}`;
}

// A step over the whole range ("*/15") as its step, else undefined.
function everyN(s: Set<number>, min: number, max: number): number | undefined {
  const v = sorted(s);
  if (v.length < 2 || v[0] !== min) return undefined;
  const step = v[1] - v[0];
  for (let i = 1; i < v.length; i++) if (v[i] - v[i - 1] !== step) return undefined;
  return v.at(-1)! + step > max ? step : undefined;
}

// Plain words for the common shapes; the cron itself for anything else.
export function describeCron(spec: CronSpec, zone?: string): string {
  const mins = sorted(spec.minutes);
  const hours = sorted(spec.hours);
  const allHours = hours.length === 24;
  const allDays = !spec.daysRestricted && !spec.weekdaysRestricted && spec.days.size === 31 && spec.weekdays.size === 7;
  const allMonths = spec.months.size === 12;
  const suffix = zone ? ` (${zone})` : '';

  const minuteStep = everyN(spec.minutes, 0, 59);
  if (allHours && allDays && allMonths) {
    if (mins.length === 60) return `Every minute${suffix}`;
    if (minuteStep) return `Every ${minuteStep} minutes${suffix}`;
    if (mins.length === 1) return mins[0] === 0 ? `Every hour${suffix}` : `Every hour at :${pad(mins[0])}${suffix}`;
  }
  const hourStep = everyN(spec.hours, 0, 23);
  if (mins.length === 1 && hourStep && allDays && allMonths) {
    return `Every ${hourStep} hours${mins[0] ? ` at :${pad(mins[0])}` : ''}${suffix}`;
  }

  // From here, one or a few times of day.
  if (mins.length !== 1 || hours.length > 4) return `Cron ${spec.source}${suffix}`;
  const times = listWords(hours.map((h) => `${h}:${pad(mins[0])}`));

  let days: string;
  if (allDays) days = 'Every day';
  else if (spec.weekdaysRestricted && !spec.daysRestricted) {
    const wd = sorted(spec.weekdays);
    if (wd.join() === '1,2,3,4,5') days = 'Weekdays';
    else if (wd.join() === '0,6') days = 'Weekends';
    else days = `Every ${listWords(wd.map((d) => DAY_NAMES[d]))}`;
  } else if (spec.daysRestricted && !spec.weekdaysRestricted) {
    const d = sorted(spec.days);
    if (d.length > 3) return `Cron ${spec.source}${suffix}`;
    days = `On the ${listWords(d.map(ordinal))}`;
  } else return `Cron ${spec.source}${suffix}`;

  if (!allMonths) {
    const mo = sorted(spec.months);
    if (mo.length > 3) return `Cron ${spec.source}${suffix}`;
    days += ` of ${listWords(mo.map((m) => MONTH_NAMES[m - 1]))}`;
  } else if (days.startsWith('On the')) days += ' of every month';
  return `${days} at ${times}${suffix}`;
}

// "Once, Tue 28 Oct at 15:30" in the zone, with the year only when it
// isn't this year's.
export function describeAt(ms: number, zone: string, nowMs = Date.now()): string {
  const w = wallAt(ms, zone);
  const dow = DAY_NAMES[new Date(Date.UTC(w.y, w.mo - 1, w.d)).getUTCDay()].slice(0, 3);
  const year = w.y === wallAt(nowMs, zone).y ? '' : ` ${w.y}`;
  return `Once, ${dow} ${w.d} ${MONTH_NAMES[w.mo - 1].slice(0, 3)}${year} at ${w.h}:${pad(w.mi)}`;
}
