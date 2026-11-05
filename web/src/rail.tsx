// The column of views down the window's left edge, as on the Mac: Threads,
// Scheduled and Projects at the top, then a tile for each runner, Usage and the
// gear at the foot. On a phone it lies down as a tab bar (styles.css), with
// Runners and Usage under More.
import { useQuery } from 'convex/react';
import type { ReactNode } from 'react';
import { api } from '../../convex/_generated/api';
import { useLiveQuery } from './live';
import { useInbox } from './inbox';
import { MenuChoice, Pop } from './menu';
import { go, type RailView, type Route, viewPath } from './route';
import { build, wakesOf } from './sections';
import { useTheme } from './pages';
import { signOut } from './token';
import { day } from './format';
import { isOnline, runnersShown, runnerState } from './view-logic';
import * as Icon from './icons';

// Where Threads goes back to: the thread last open, so a trip to Scheduled and
// back lands where it started. On a phone, the list.
let lastThread: string | undefined;

export function Rail({ token, route }: { token: string; route: Route }) {
  const inbox = useInbox();
  // The small rows, not phone:schedules: this is on screen all the time.
  const wakes = useLiveQuery(api.phone.wakes, { token });
  const runners = useLiveQuery(api.phone.runners, { token });
  const now = Date.now();
  if (route.page === 'thread') lastThread = route.threadId;
  const waiting = build(inbox ?? [], now, wakesOf(wakes ?? []), 'needsYou').inbox.length;
  const active = wakes?.length ?? 0;
  const threads = route.page === 'list' || route.page === 'thread' || route.page === 'new';
  const narrow = () => matchMedia('(max-width: 760px)').matches;

  const view = (name: RailView, title: string, icon: ReactNode, badge?: number) => (
    <a
      className={`rail-btn ${route.page === name ? 'on' : ''}`}
      href={viewPath(name)}
      title={title}
      aria-label={title}
      onClick={(e) => {
        e.preventDefault();
        go(viewPath(name));
      }}
    >
      {icon}
      <span className="word">{title}</span>
      {badge ? <b>{badge}</b> : null}
    </a>
  );

  return (
    <nav className="rail" aria-label="Views">
      <img className="brand-mark" src="/icon.png" alt="Threadbear" title="Threadbear" width={24} height={24} />
      <a
        className={`rail-btn ${threads ? 'on' : ''}`}
        href="/"
        title="Threads"
        aria-label="Threads"
        onClick={(e) => {
          e.preventDefault();
          go(lastThread && !narrow() && !threads ? `/t/${encodeURIComponent(lastThread)}` : '/');
        }}
      >
        <Icon.Bubbles />
        <span className="word">Threads</span>
        {waiting ? <b>{waiting}</b> : null}
      </a>
      {view('scheduled', 'Scheduled', <Icon.Clock />, active)}
      {view('projects', 'Projects', <Icon.Stack />)}
      <span className="grow" />
      {runnersShown(runners ?? [], now).map((r) => (
        <a
          key={r.runnerId}
          className={`tile ${isOnline(r, now) ? 'ok' : ''} ${isOnline(r, now) && r.pressure ? 'warn' : ''} ${route.page === 'runners' && route.id === r.runnerId ? 'on' : ''}`}
          href={viewPath('runners', r.runnerId)}
          title={tileWords(r, now)}
          aria-label={tileWords(r, now)}
          onClick={(e) => {
            e.preventDefault();
            go(viewPath('runners', r.runnerId));
          }}
        >
          {r.name.slice(0, 1)}
        </a>
      ))}
      <span className="rail-sep" />
      <span className="desk-only">{view('usage', 'Usage', <Icon.Bars />)}</span>
      <GearMenu token={token} />
    </nav>
  );
}

function tileWords(r: Parameters<typeof runnerState>[0] & { name: string; pressure?: string }, now: number): string {
  return `${r.name}: ${runnerState(r, now)}${r.pressure && isOnline(r, now) ? `. Low on ${r.pressure}` : ''}`;
}

function GearMenu({ token }: { token: string }) {
  const me = useQuery(api.phone.me, { token });
  const [theme, pick] = useTheme();
  const row = (close: () => void, label: string, icon: ReactNode, run: () => void, className = '') => (
    <button
      className={className}
      title={label}
      onClick={() => {
        run();
        close();
      }}
    >
      {icon}
      {label}
    </button>
  );
  return (
    <Pop title="Settings" icon={<Icon.Gear />}>
      {(close) => (
        <>
          {row(close, 'Runners', <Icon.Server />, () => go(viewPath('runners')), 'phone-only')}
          {row(close, 'Usage', <Icon.Bars />, () => go(viewPath('usage')), 'phone-only')}
          <hr className="phone-only" />
          <MenuChoice icon={<Icon.Gear />} label="Follow the system" on={theme === 'system'} pick={() => pick('system')} />
          <MenuChoice icon={<Icon.Sun />} label="Always light" on={theme === 'light'} pick={() => pick('light')} />
          <MenuChoice icon={<Icon.Moon />} label="Always dark" on={theme === 'dark'} pick={() => pick('dark')} />
          <hr />
          <div className="note-line" title="How long this browser stays signed in">
            <Icon.Globe />
            {me ? `Signed in until ${day(me.expiresAt)}` : 'Signed in on this browser'}
          </div>
          {row(close, 'Sign out', <Icon.SignOut />, signOut)}
        </>
      )}
    </Pop>
  );
}
