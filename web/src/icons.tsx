// Line icons in the SF Symbols style the apps use, drawn here so the page
// needs no icon font. Each takes the text colour.
const base = { fill: 'none', stroke: 'currentColor', strokeWidth: 1.6, strokeLinecap: 'round', strokeLinejoin: 'round', viewBox: '0 0 16 16', 'aria-hidden': true } as const;

export const Share = () => (
  <svg {...base}>
    <path d="M8 10V2M5 4.5 8 1.6l3 2.9M5.5 7H4v7.5h8V7h-1.5" />
  </svg>
);
export const More = () => (
  <svg {...base} fill="currentColor" stroke="none">
    <circle cx="3.5" cy="8" r="1.3" />
    <circle cx="8" cy="8" r="1.3" />
    <circle cx="12.5" cy="8" r="1.3" />
  </svg>
);
export const Back = () => (
  <svg {...base}>
    <path d="M10 2.5 4.5 8l5.5 5.5" />
  </svg>
);
export const Up = () => (
  <svg {...base} strokeWidth={2}>
    <path d="M8 13.5v-11M3.5 7 8 2.5 12.5 7" />
  </svg>
);
export const Chevron = ({ className }: { className?: string }) => (
  <svg {...base} className={className}>
    <path d="m6 3.5 4.5 4.5L6 12.5" />
  </svg>
);
export const ChevronDown = () => (
  <svg {...base} width={12} height={12}>
    <path d="m3.5 6 4.5 4.5L12.5 6" />
  </svg>
);
export const Link = () => (
  <svg {...base}>
    <path d="M6.8 9.2a2.8 2.8 0 0 0 4 0l2.3-2.3a2.8 2.8 0 0 0-4-4L8.3 3.7M9.2 6.8a2.8 2.8 0 0 0-4 0L2.9 9.1a2.8 2.8 0 0 0 4 4l.8-.8" />
  </svg>
);
export const Inbox = () => (
  <svg {...base}>
    <path d="M1.8 9 3.6 3h8.8l1.8 6v4H1.8zM1.8 9h3.7l.8 1.6h3.4l.8-1.6h3.7" />
  </svg>
);
export const Bolt = () => (
  <svg {...base}>
    <path d="M9 1.5 3.5 9H8l-1 5.5L12.5 7H8z" />
  </svg>
);
export const Moon = () => (
  <svg {...base}>
    <path d="M13.5 9.6A6 6 0 0 1 6.4 2.5a6 6 0 1 0 7.1 7.1z" />
  </svg>
);
export const Archive = () => (
  <svg {...base}>
    <path d="M1.8 2.5h12.4v3H1.8zM2.8 5.5v8h10.4v-8M6.3 8.5h3.4" />
  </svg>
);
export const Star = () => (
  <svg {...base}>
    <path d="m8 1.8 1.9 3.9 4.3.6-3.1 3 .7 4.3L8 11.6l-3.8 2 .7-4.3-3.1-3 4.3-.6z" />
  </svg>
);
