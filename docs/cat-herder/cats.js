// Flat cat sprites for the Cat Herder concept mockups. One <symbol> per
// posture; the posture is the thread's state. Coat colour comes from the
// `color` of the <use>, eye colour from --eye.
//
//   sit     idle, a settled thread
//   door    needs you: sat at the door, eyes wide, meowing
//   hunt    running: low and stretched, chasing the laser
//   loaf    finished and read: tucked in, eyes closed
//   gift    finished, unread: sat next to the mouse it brought you
//   sleep   snoozed: curled up, Zs
//   hairball failed: looking sheepish next to the mess
//   laser   the red dot the hunting cats chase
document.write(`
<svg width="0" height="0" style="position:absolute" aria-hidden="true">
  <defs>
    <g id="cat-ears">
      <polygon points="21,21 23,7 32,16" fill="currentColor"/>
      <polygon points="43,21 41,7 32,16" fill="currentColor"/>
    </g>
    <g id="cat-eyes-open">
      <ellipse cx="27" cy="26" rx="2.6" ry="3" fill="var(--eye,#d9e86b)"/>
      <ellipse cx="37" cy="26" rx="2.6" ry="3" fill="var(--eye,#d9e86b)"/>
      <rect x="26.3" y="23.5" width="1.4" height="5" rx="0.7" fill="#1b1b1b"/>
      <rect x="36.3" y="23.5" width="1.4" height="5" rx="0.7" fill="#1b1b1b"/>
    </g>
    <g id="cat-eyes-wide">
      <circle cx="27" cy="26" r="3.6" fill="var(--eye,#d9e86b)"/>
      <circle cx="37" cy="26" r="3.6" fill="var(--eye,#d9e86b)"/>
      <circle cx="27" cy="26" r="2.2" fill="#1b1b1b"/>
      <circle cx="37" cy="26" r="2.2" fill="#1b1b1b"/>
      <circle cx="28" cy="25" r="0.8" fill="#fff"/>
      <circle cx="38" cy="25" r="0.8" fill="#fff"/>
    </g>
    <g id="cat-eyes-closed" fill="none" stroke="#1b1b1b" stroke-width="1.4" stroke-linecap="round">
      <path d="M24 26 q3 2.5 6 0"/>
      <path d="M34 26 q3 2.5 6 0"/>
    </g>
    <g id="cat-head">
      <use href="#cat-ears"/>
      <circle cx="32" cy="26" r="12.5" fill="currentColor"/>
    </g>

    <symbol id="cat-sit" viewBox="0 0 64 64">
      <path d="M50 58 q10 -4 6 -16" fill="none" stroke="currentColor" stroke-width="5" stroke-linecap="round"/>
      <ellipse cx="32" cy="47" rx="14" ry="15" fill="currentColor"/>
      <use href="#cat-head"/>
      <use href="#cat-eyes-open"/>
    </symbol>

    <symbol id="cat-door" viewBox="0 0 64 64">
      <path d="M50 58 q12 -2 8 -16" fill="none" stroke="currentColor" stroke-width="5" stroke-linecap="round"/>
      <ellipse cx="32" cy="47" rx="14" ry="15" fill="currentColor"/>
      <use href="#cat-head"/>
      <use href="#cat-eyes-wide"/>
      <ellipse cx="32" cy="33" rx="2" ry="1.6" fill="#1b1b1b"/>
      <g fill="none" stroke="var(--sound,#9aa0a6)" stroke-width="1.5" stroke-linecap="round">
        <path d="M52 22 q3 4 0 8"/>
        <path d="M56 19 q5 7 0 14"/>
      </g>
    </symbol>

    <symbol id="cat-hunt" viewBox="0 0 64 64">
      <path d="M8 44 q-8 -12 6 -20" fill="none" stroke="currentColor" stroke-width="5" stroke-linecap="round"/>
      <path d="M6 54 C6 44 14 40 24 40 L44 40 C52 40 58 44 58 54 Z" fill="currentColor"/>
      <polygon points="46,36 50,24 56,34" fill="currentColor"/>
      <polygon points="58,34 62,24 64,36" fill="currentColor"/>
      <circle cx="54" cy="40" r="10" fill="currentColor"/>
      <circle cx="59" cy="38" r="2.6" fill="var(--eye,#d9e86b)"/>
      <circle cx="59.5" cy="38" r="1.3" fill="#1b1b1b"/>
      <path d="M18 54 l-4 6" stroke="currentColor" stroke-width="6" stroke-linecap="round"/>
      <path d="M48 54 l6 6" stroke="currentColor" stroke-width="6" stroke-linecap="round"/>
    </symbol>

    <symbol id="cat-loaf" viewBox="0 0 64 64">
      <rect x="10" y="30" width="44" height="28" rx="14" fill="currentColor"/>
      <path d="M12 50 q-6 8 6 8" fill="none" stroke="currentColor" stroke-width="5" stroke-linecap="round"/>
      <use href="#cat-head"/>
      <use href="#cat-eyes-closed"/>
    </symbol>

    <symbol id="cat-gift" viewBox="0 0 64 64">
      <path d="M42 58 q10 -4 6 -16" fill="none" stroke="currentColor" stroke-width="5" stroke-linecap="round"/>
      <ellipse cx="26" cy="47" rx="13" ry="15" fill="currentColor"/>
      <g transform="translate(-6 0)"><use href="#cat-head"/><use href="#cat-eyes-open"/></g>
      <ellipse cx="54" cy="57" rx="7" ry="4.5" fill="var(--mouse,#8e8e93)"/>
      <circle cx="49" cy="54" r="2" fill="var(--mouse,#8e8e93)"/>
      <circle cx="48.5" cy="57" r="0.8" fill="#1b1b1b"/>
      <path d="M61 57 q5 -3 2 -8" fill="none" stroke="var(--mouse,#8e8e93)" stroke-width="1.5" stroke-linecap="round"/>
    </symbol>

    <symbol id="cat-sleep" viewBox="0 0 64 64">
      <circle cx="34" cy="42" r="18" fill="currentColor"/>
      <path d="M18 50 q-4 -14 14 -12" fill="none" stroke="currentColor" stroke-width="5" stroke-linecap="round"/>
      <g transform="translate(-10 12) scale(0.85)">
        <use href="#cat-ears"/>
        <circle cx="32" cy="26" r="12.5" fill="currentColor"/>
        <use href="#cat-eyes-closed"/>
      </g>
      <text x="46" y="20" font-size="9" font-weight="700" fill="var(--sound,#9aa0a6)" font-family="-apple-system, system-ui">z</text>
      <text x="53" y="12" font-size="12" font-weight="700" fill="var(--sound,#9aa0a6)" font-family="-apple-system, system-ui">z</text>
    </symbol>

    <symbol id="cat-hairball" viewBox="0 0 64 64">
      <path d="M48 58 q10 -4 6 -16" fill="none" stroke="currentColor" stroke-width="5" stroke-linecap="round"/>
      <ellipse cx="34" cy="47" rx="13" ry="15" fill="currentColor"/>
      <g transform="translate(2 0)"><use href="#cat-head"/></g>
      <g fill="none" stroke="#1b1b1b" stroke-width="1.4" stroke-linecap="round" transform="translate(2 0)">
        <path d="M24 24 l6 3"/><path d="M40 24 l-6 3"/>
      </g>
      <path d="M6 58 q3 -8 7 -1 t7 -1 t6 0" fill="none" stroke="var(--mess,#a08a5a)" stroke-width="3" stroke-linecap="round"/>
    </symbol>

    <symbol id="laser" viewBox="0 0 24 24">
      <circle cx="12" cy="12" r="9" fill="#ff3b30" opacity="0.18"/>
      <circle cx="12" cy="12" r="5" fill="#ff3b30" opacity="0.5"/>
      <circle cx="12" cy="12" r="2.5" fill="#ff6b61"/>
    </symbol>
  </defs>
</svg>`);

// Coat colours, picked per thread from a hash of its id so a thread keeps
// its cat for life.
window.COATS = {
  ginger: '#e5953f', grey: '#9aa0a6', black: '#5a5a60', cream: '#e8d9b5',
  tabby: '#b07a4a', tortie: '#7a5230', white: '#f2f2f2', blue: '#6e7a8a',
};
