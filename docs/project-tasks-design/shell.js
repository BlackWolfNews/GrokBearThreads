// Builds today's window around each mockup's own parts, so the files only
// hold what differs. Call shell({...}) from a script at the end of the
// body; it fills <div id="win">.
const P = {
  patch: '<rect x="2.5" y="2.5" width="11" height="11" rx="2.6" stroke-dasharray="2.2 1.8"/>',
  rule: '<path d="M2.5 4h9M2.5 7.5h9M2.5 11h4.5M11.5 9.3v4.4M9.3 11.5h4.4"/>',
  info: '<circle cx="8" cy="8" r="6"/><path d="M8 7.2v3.6M8 5.2v.1"/>',
  x: '<path d="M4.5 4.5l7 7M11.5 4.5l-7 7"/>',
  check: '<path d="M3.5 8.5l3 3 6-7"/>',
  plus: '<path d="M8 3.5v9M3.5 8h9"/>',
  pin: '<path d="M6 2.5h4M6.5 2.5v4l-2 2.5h7l-2-2.5v-4M8 9v4.5"/>',
  list: '<path d="M5.5 4.5h8M5.5 8h8M5.5 11.5h8M2.5 4.5h.1M2.5 8h.1M2.5 11.5h.1"/>',
  share: '<path d="M8 2.5v8M5 5l3-3 3 3M4.5 8H3.5v5.5h9V8h-1"/>',
  more: '<path d="M3.5 8h.1M8 8h.1M12.5 8h.1" stroke-width="2"/>',
  search: '<circle cx="7" cy="7" r="4.2"/><path d="M10.2 10.2l3.3 3.3"/>',
  compose: '<path d="M9 3H3.5v9.5H13V7M7 9l.4-2 5-5 1.6 1.6-5 5z"/>',
  spark: '<path d="M8 2.5l1.3 4.2 4.2 1.3-4.2 1.3L8 13.5l-1.3-4.2L2.5 8l4.2-1.3z"/>',
  lock: '<rect x="3.5" y="7" width="9" height="6.5" rx="1.5"/><path d="M5.5 7V5a2.5 2.5 0 0 1 5 0"/>',
  upArrow: '<path d="M8 13V3.5M4 7.5l4-4 4 4"/>',
  chevD: '<path d="M5 6.5l3 3 3-3"/>',
  chevR: '<path d="M6.5 4.5l3 3.5-3 3.5"/>',
  tray: '<path d="M2.5 9.5l2-6h7l2 6v3.5h-11zM2.5 9.5h3.5l.8 1.5h2.4l.8-1.5h3.5"/>',
  sort: '<path d="M5 13V3M2.5 5.5L5 3l2.5 2.5M11 3v10M8.5 10.5L11 13l2.5-2.5"/>',
  bolt: '<path d="M9 2L4 9h4l-1 5 5-7H8z"/>',
  chat: '<path d="M2.5 3.5h8v6h-5l-3 2.5zM10.5 6h3v6l-2-1.5h-4.5V9.5"/>',
  clock: '<circle cx="8" cy="8" r="5.5"/><path d="M8 5v3.2l2 1.3"/>',
  layers: '<path d="M8 2.5l5.5 3L8 8.5 2.5 5.5zM2.5 8L8 11l5.5-3M2.5 10.5L8 13.5l5.5-3"/>',
  books: '<path d="M3 3v10.5M6 3v10.5M3 3h3M3 13.5h3M8.5 4.5l2.5-1 3 9.5-2.5 1z"/>',
  plug: '<path d="M2.5 9h3M10.5 9h3M5.5 6.5h5v5h-5zM7 6.5V4.5M9 6.5V4.5"/>',
  down: '<circle cx="8" cy="8" r="5.5"/><path d="M8 5v5.5M5.8 8.5L8 10.7l2.2-2.2"/>',
  gauge: '<circle cx="8" cy="8" r="5.5"/><path d="M8 8l2.5-2.5M5 11l-.6.6M11 11l.6.6"/>',
  gear: '<circle cx="8" cy="8" r="2"/><path d="M8 2v1.6M8 12.4V14M2 8h1.6M12.4 8H14M3.8 3.8l1.1 1.1M11.1 11.1l1.1 1.1M3.8 12.2l1.1-1.1M11.1 4.9l1.1-1.1"/>',
  folder: '<path d="M2.5 4.5h4l1.2 1.4h5.8v6.6h-11z"/>',
  hdd: '<rect x="2" y="6" width="12" height="4.5" rx="1"/><path d="M4.5 8.3h.1M6.5 8.3h.1"/>',
  doc: '<path d="M4 2.5h5l3 3v8H4zM9 2.5v3h3"/>',
  photo: '<rect x="2.5" y="3.5" width="11" height="9" rx="1.5"/><path d="M2.5 11l3.5-3.5 3 3 2-2 2.5 2.5"/>',
  hourglass: '<path d="M4.5 2.5h7M4.5 13.5h7M5 2.5c0 3 6 4 6 5.5S5 10.5 5 13.5M11 2.5c0 3-6 4-6 5.5s6 2.5 6 5.5"/>',
  history: '<path d="M3 8a5 5 0 1 0 1.5-3.5M3 3v2.5h2.5M8 5.5V8l1.8 1.2"/>',
}
const I = (n, cls = '') => `<svg class="i ${cls}" viewBox="0 0 16 16">${P[n]}</svg>`
const BEAR = '../../app/icons/threadbear.png'
const LIBRARIAN_ART = '../../app/Sources/Threadbear/Resources/Art/librarian.png'
const DOT = '<span style="position:absolute;right:3px;top:3px;width:5px;height:5px;border-radius:50%;background:rgba(255,255,255,.7)"></span>'

// The one real example, from the eval over Mike's threads (30 Oct).
const RULE_TITLE = 'Show what you mention'
const RULE_LINE = 'When you mention something for me to read or look at (a draft, script, file, image, walkthrough or explanation), make sure I can see it from this reply: paste short text in, and pin files and links.'
const EVIDENCE = [
  ['Thu', 'Sorry, I don\'t see the draft message for Peter. Where is it?', 'Checking photos for the Port Geograph…'],
  ['Wed', 'It says the explanation is above, but I don\'t actually get to see it', 'Threadbear reply rule and schedule'],
  ['Wed', 'Where is it? I don\'t see it?', 'Agent-driven Threadbear install'],
  ['Tue', 'But the image doesn\'t show up here in Threadbare either?', 'Share a thread on the web'],
  ['Tue', 'Where\'s the script? Have you got a link to it, please?', 'Poddle 1.0.4 release'],
  ['Tue', 'Where is the tandem puddle? I don\'t see it.', 'Patches for video and Tandem work'],
]

function shell(o) {
  const av = a => a === 'bear' ? `<div class="av"><img src="${BEAR}"></div>`
    : a.length === 1 ? `<div class="av">${a}</div>` : `<div class="av">${I(a)}</div>`
  const row = ([mk, a, t, f, st, cls = '', b = false]) =>
    `<div class="row ${cls}"><div class="mk">${mk}</div>${av(a)}<div style="min-width:0"><div class="t ${b ? 'b' : ''}">${t}</div><div class="f">${f}</div></div><div class="st ${st[1] || ''}">${st[0]}</div></div>`
  const inbox = [
    ['', 'P', 'Pick a colour for the Poddle share sheet', 'Poddle', ['Needs you', 'ny'], '', true],
    ['', 'folder', 'Checking photos for the Port Geograph competition', 'misc', ['now'], 'sel', true],
    ['●', 'bear', 'Tour step 3 points at the wrong chip', 'Threadbear', ['1h'], '', true],
    ['', 'W', 'Re-check the Walkies battery numbers', 'Walkies', ['3h']],
    ['', 'folder', 'Clear the Backblaze churn rules', 'misc', ['Wed']],
    ['', 'bear', 'Patch chips overflow on narrow windows', 'Threadbear', ['Wed']],
    ['', 'hdd', 'Check the photo library backup', 'misc', ['Tue']],
  ]
  const running = [['', 'hdd', 'Render the shed walkthrough', 'On bruce', ['4m 12s', 'run']]]
  const side = o.side || `<div class="search">${I('search', 's')} Search threads</div>
      <div class="compose">${I('compose')}</div>
      <div class="sec">${I('tray', 's')} Inbox <span class="ln"></span>${I('sort', 's')}</div>
      ${inbox.map(row).join('')}
      <div class="sec">${I('bolt', 's')} Running <span class="ln"></span></div>
      ${running.map(row).join('')}`
  const main = o.main || `<div class="thread">
      <div class="head"><div class="av" style="background:none;color:var(--second)">${I('folder')}</div>Checking photos for the Port Geograph competition<div class="r">${I('share')}${I('more')}</div></div>
      <div class="tx">${o.transcript}</div>
      <div class="comp">
        <div class="msg">Message</div>
        <div class="bar">${I('plus')}<span class="x">${I('spark', 's')} Claude · Opus 5.5 ${I('chevD', 's')}</span><span class="x">${I('lock', 's')} Full access ${I('chevD', 's')}</span><span class="send">${I('upArrow')}</span></div>
      </div>
      ${o.overlay || ''}
    </div>`
  const lib = o.librarian
  document.getElementById('win').innerHTML = `
  <div class="win">
    <div class="lights"><i></i><i></i><i></i></div>
    <div class="lrail">
      <div class="b ${lib ? '' : 'on'}">${I('chat', 'l')}<span class="n">3</span></div>
      <div class="b">${I('clock', 'l')}<span class="n">6</span></div>
      <div class="b">${I('layers', 'l')}</div>
      <div class="b ${lib ? 'on' : ''}">${I('books', 'l')}${o.libDot ? DOT : '<span class="n">4</span>'}</div>
      <div class="sp"></div>
      <div class="b">${I('plug', 'l')}</div>
      <div class="b">${I('down', 'l')}</div>
      <div class="b">${I('gauge', 'l')}</div>
      <div class="b" style="margin-bottom:12px">${I('gear', 'l')}</div>
    </div>
    <div class="side">${side}</div>
    ${main}
    ${o.pane ?? highlightsPane()}
    <div class="rrail">
      <div class="b on">${I('pin', 'l')}</div>
      <div class="sp"></div>
      <div class="b">${I('patch', 'l')}</div>
    </div>
  </div>`
}

// The librarian's brief at the top of Highlights: secondary text, a bullet
// per point (HighlightsView.swift). `extra` goes after its points.
function highlightsPane(extra = '', briefStyle = '') {
  return `<div class="pane"><div class="tabs"><span class="tab on">${I('pin', 's')} Highlights</span></div><div class="pbody" style="overflow:visible">
    <div class="lib brief" style="${briefStyle}"><div><span>•</span><span>5 of 31 weekend photos fit the competition rules.</span></div><div><span>•</span><span>The message to Peter is drafted and pinned, not sent.</span></div>${extra}</div>
    <div class="ph">Pinned</div>
    <div class="prow">${I('doc', 's')}<div>Draft for Peter<div class="sub">The message with the five photos</div></div></div>
    <div class="ph">Files</div>
    ${['DSC_2041.jpg', 'DSC_2057.jpg', 'DSC_2113.jpg', 'DSC_2120.jpg', 'DSC_2188.jpg'].map(f => `<div class="prow">${I('photo', 's')}<div>${f}<div class="sub">~/Pictures/2026-10-25 Weekend</div></div></div>`).join('')}
  </div></div>`
}

// Today's transcript in the thread where the repeat just happened.
function firstTurn() {
  return `<div class="bubble">Go through my photos from the weekend and pick the ones that fit the Port Geograph competition rules. Then draft a message to Peter with the shortlist.</div>
  <div class="work">Worked for 3m 48s ${I('chevR', 's')}</div>
  <div class="reply"><ul><li>5 of 31 photos fit: landscape, over 3000 px wide and taken this year <a>↑</a></li><li>Drafted the message to Peter with the five attached and the entry deadline</li></ul></div>
  <div class="meta">3m 52s · $0.41</div>`
}
function repeatBubble(after = '') {
  return `<div class="bubble">Sorry, I don't see the draft message for Peter. Where is it?</div>${after}`
}
function secondTurn(card) {
  return `<div class="work">Worked for 14s ${I('chevR', 's')}</div>
  <div class="reply"><p>Sorry, here it is. It's pinned in Highlights too.</p>
  <blockquote>Hi Peter, here are my five for the Port Geograph comp. Happy to swap any out if you think another one's stronger. Entries close Sunday.</blockquote></div>
  <div class="meta">18s · $0.06</div>
  ${card ?? doneCard()}`
}
function doneCard(extra = '') {
  return `<div class="done"><div class="top">${I('check')} Done <span class="btn">Archive</span></div>
  <div class="oc">Or carry on</div>
  <div class="fu">Resize the five to the 3000 px limit</div>${extra}</div>`
}

// The evidence and what accepting does, behind the ⓘ everywhere.
function evidence(cls, style, title = 'Asked 7 times on 4 days') {
  return `<div class="pop ${cls}" style="${style}">
    <b>${title}</b>
    <div class="ev">${EVIDENCE.map(([d, q, t]) => `<div><span class="qq">“${q}”</span><span class="tt">${d} · ${t}</span></div>`).join('')}</div>
    <div class="w">Adds this line to <code>~/.claude/CLAUDE.md</code>, for every agent:
      <div class="rl">${RULE_LINE}</div>
      Undo takes it out again. × and it's never offered again.</div>
  </div>`
}
