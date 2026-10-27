// Flat teddy-bear sprites for the Threadbear mockups. One bear, the app's
// mascot (not one per thread). Coat is currentColor; --muzzle, --patch and
// --stitch tint the lighter muzzle, the sewn patch and its stitches.
//
//   bear-sit    idle, the default
//   bear-wave   "bear with me": a turn is running, paw raised
//   bear-sleep  hibernating: snoozed thread, or the runner idle
//   bear-patch  holding up a patch it just sewed (a project patch was added)
//   bear-dizzy  unbearable: a failed turn
//   cub         a sub-agent
//   patch       a sewn fabric patch on its own (the icon for project patches)
//   honey       a honey pot, fill level via --level (0 to 1) as a clip
document.write(`
<svg width="0" height="0" style="position:absolute" aria-hidden="true">
  <defs>
    <g id="bear-ears">
      <circle cx="19" cy="15" r="6.5" fill="currentColor"/>
      <circle cx="45" cy="15" r="6.5" fill="currentColor"/>
      <circle cx="19" cy="15" r="3" fill="var(--muzzle,#e9c99a)" opacity="0.8"/>
      <circle cx="45" cy="15" r="3" fill="var(--muzzle,#e9c99a)" opacity="0.8"/>
    </g>
    <g id="bear-face">
      <circle cx="32" cy="24" r="14" fill="currentColor"/>
      <ellipse cx="32" cy="29" rx="7" ry="5" fill="var(--muzzle,#e9c99a)"/>
      <ellipse cx="32" cy="27" rx="2.4" ry="1.7" fill="#2a1d10"/>
      <circle cx="26.5" cy="22" r="1.8" fill="#2a1d10"/>
      <!-- the button eye, with its thread cross -->
      <circle cx="37.5" cy="22" r="2.6" fill="#3b2a18"/>
      <path d="M36.5 21 l2 2 M38.5 21 l-2 2" stroke="var(--stitch,#f3e4c4)" stroke-width="0.7"/>
    </g>
    <g id="bear-cheek-patch">
      <rect x="38" y="25" width="7" height="6" rx="1.5" fill="var(--patch,#7a9bb8)"/>
      <rect x="38" y="25" width="7" height="6" rx="1.5" fill="none" stroke="var(--stitch,#f3e4c4)" stroke-width="0.8" stroke-dasharray="1.2 1.2"/>
    </g>
    <g id="bear-body-patch">
      <rect x="20" y="42" width="9" height="8" rx="2" fill="var(--patch2,#b85c5c)"/>
      <rect x="20" y="42" width="9" height="8" rx="2" fill="none" stroke="var(--stitch,#f3e4c4)" stroke-width="0.8" stroke-dasharray="1.2 1.2"/>
    </g>

    <symbol id="bear-sit" viewBox="0 0 64 64">
      <ellipse cx="32" cy="48" rx="16" ry="14" fill="currentColor"/>
      <ellipse cx="32" cy="50" rx="8" ry="7" fill="var(--muzzle,#e9c99a)" opacity="0.55"/>
      <ellipse cx="16" cy="52" rx="5" ry="7" fill="currentColor"/>
      <ellipse cx="48" cy="52" rx="5" ry="7" fill="currentColor"/>
      <use href="#bear-body-patch"/>
      <use href="#bear-ears"/>
      <use href="#bear-face"/>
      <use href="#bear-cheek-patch"/>
    </symbol>

    <symbol id="bear-wave" viewBox="0 0 64 64">
      <ellipse cx="32" cy="48" rx="16" ry="14" fill="currentColor"/>
      <ellipse cx="32" cy="50" rx="8" ry="7" fill="var(--muzzle,#e9c99a)" opacity="0.55"/>
      <ellipse cx="16" cy="52" rx="5" ry="7" fill="currentColor"/>
      <path d="M46 48 L54 30" stroke="currentColor" stroke-width="9" stroke-linecap="round"/>
      <circle cx="55" cy="28" r="5" fill="var(--muzzle,#e9c99a)"/>
      <use href="#bear-body-patch"/>
      <use href="#bear-ears"/>
      <use href="#bear-face"/>
      <use href="#bear-cheek-patch"/>
    </symbol>

    <symbol id="bear-sleep" viewBox="0 0 64 64">
      <ellipse cx="34" cy="44" rx="22" ry="15" fill="currentColor"/>
      <ellipse cx="40" cy="47" rx="9" ry="6" fill="var(--muzzle,#e9c99a)" opacity="0.5"/>
      <rect x="40" y="36" width="9" height="8" rx="2" fill="var(--patch2,#b85c5c)"/>
      <rect x="40" y="36" width="9" height="8" rx="2" fill="none" stroke="var(--stitch,#f3e4c4)" stroke-width="0.8" stroke-dasharray="1.2 1.2"/>
      <g transform="translate(-12 10) scale(0.95)">
        <use href="#bear-ears"/>
        <circle cx="32" cy="24" r="14" fill="currentColor"/>
        <ellipse cx="32" cy="29" rx="7" ry="5" fill="var(--muzzle,#e9c99a)"/>
        <ellipse cx="32" cy="27" rx="2.4" ry="1.7" fill="#2a1d10"/>
        <path d="M24 22 q2.5 2 5 0 M35 22 q2.5 2 5 0" fill="none" stroke="#2a1d10" stroke-width="1.3" stroke-linecap="round"/>
      </g>
      <text x="44" y="18" font-size="9" font-weight="700" fill="var(--zz,#9aa0a6)" font-family="-apple-system, system-ui">z</text>
      <text x="51" y="10" font-size="12" font-weight="700" fill="var(--zz,#9aa0a6)" font-family="-apple-system, system-ui">z</text>
    </symbol>

    <symbol id="bear-patch" viewBox="0 0 64 64">
      <ellipse cx="32" cy="48" rx="16" ry="14" fill="currentColor"/>
      <ellipse cx="32" cy="50" rx="8" ry="7" fill="var(--muzzle,#e9c99a)" opacity="0.55"/>
      <path d="M18 50 L10 40 M46 50 L54 40" stroke="currentColor" stroke-width="9" stroke-linecap="round"/>
      <use href="#bear-ears"/>
      <use href="#bear-face"/>
      <use href="#bear-cheek-patch"/>
      <g transform="translate(2 -4)">
        <rect x="6" y="34" width="20" height="16" rx="3" fill="var(--patch,#7a9bb8)" transform="rotate(-8 16 42)"/>
        <rect x="6" y="34" width="20" height="16" rx="3" fill="none" stroke="var(--stitch,#f3e4c4)" stroke-width="1.2" stroke-dasharray="2 2" transform="rotate(-8 16 42)"/>
      </g>
    </symbol>

    <symbol id="bear-dizzy" viewBox="0 0 64 64">
      <ellipse cx="32" cy="48" rx="16" ry="14" fill="currentColor"/>
      <ellipse cx="32" cy="50" rx="8" ry="7" fill="var(--muzzle,#e9c99a)" opacity="0.55"/>
      <ellipse cx="16" cy="52" rx="5" ry="7" fill="currentColor"/>
      <ellipse cx="48" cy="52" rx="5" ry="7" fill="currentColor"/>
      <use href="#bear-body-patch"/>
      <g transform="rotate(-8 32 24)">
        <use href="#bear-ears"/>
        <circle cx="32" cy="24" r="14" fill="currentColor"/>
        <ellipse cx="32" cy="29" rx="7" ry="5" fill="var(--muzzle,#e9c99a)"/>
        <ellipse cx="32" cy="27" rx="2.4" ry="1.7" fill="#2a1d10"/>
        <path d="M24.5 20 l4 4 M28.5 20 l-4 4 M35.5 20 l4 4 M39.5 20 l-4 4" stroke="#2a1d10" stroke-width="1.4" stroke-linecap="round"/>
      </g>
      <path d="M44 8 q6 -4 8 2 q-6 3 -8 -2z" fill="none" stroke="var(--zz,#9aa0a6)" stroke-width="1.2"/>
      <circle cx="54" cy="6" r="1.5" fill="var(--zz,#9aa0a6)"/>
    </symbol>

    <symbol id="cub" viewBox="0 0 64 64">
      <g transform="translate(14 14) scale(0.56)">
        <ellipse cx="32" cy="48" rx="16" ry="14" fill="currentColor"/>
        <ellipse cx="16" cy="52" rx="5" ry="7" fill="currentColor"/>
        <ellipse cx="48" cy="52" rx="5" ry="7" fill="currentColor"/>
        <use href="#bear-ears"/>
        <circle cx="32" cy="24" r="14" fill="currentColor"/>
        <ellipse cx="32" cy="29" rx="7" ry="5" fill="var(--muzzle,#e9c99a)"/>
        <ellipse cx="32" cy="27" rx="2.4" ry="1.7" fill="#2a1d10"/>
        <circle cx="26.5" cy="22" r="1.8" fill="#2a1d10"/>
        <circle cx="37.5" cy="22" r="1.8" fill="#2a1d10"/>
      </g>
    </symbol>

    <symbol id="patch" viewBox="0 0 24 24">
      <rect x="3" y="4" width="18" height="16" rx="3" fill="var(--patch,#7a9bb8)" transform="rotate(-6 12 12)"/>
      <rect x="3" y="4" width="18" height="16" rx="3" fill="none" stroke="var(--stitch,#f3e4c4)" stroke-width="1.3" stroke-dasharray="2 2" transform="rotate(-6 12 12)"/>
    </symbol>

    <symbol id="honey" viewBox="0 0 64 64">
      <defs><clipPath id="honey-clip"><path d="M14 22 q-6 22 4 34 h28 q10 -12 4 -34z"/></clipPath></defs>
      <path d="M14 22 q-6 22 4 34 h28 q10 -12 4 -34z" fill="#2c2c30" stroke="#55555a"/>
      <rect x="0" y="22" width="64" height="40" fill="#e0a43a" clip-path="url(#honey-clip)" transform="translate(0 var(--drop,0))"/>
      <rect x="12" y="14" width="40" height="10" rx="3" fill="#3a3a3f" stroke="#55555a"/>
      <rect x="16" y="9" width="32" height="7" rx="2" fill="#4a4a50"/>
    </symbol>
  </defs>
</svg>`);
