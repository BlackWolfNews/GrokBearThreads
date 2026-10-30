// What every mockup here shares: the Projects sidebar, the project page's
// top (title, links, goals, state) and Port Geo's real tasks from its
// Notion page (Christmas Lights 2026, shared with ARG), 30 Oct.
P.notion = '<rect x="3" y="2.5" width="10" height="11" rx="1.6"/><path d="M5.8 11V5.3l4.4 5.7V5"/>'
P.board = '<rect x="2.5" y="3" width="3.2" height="10" rx=".8"/><rect x="6.4" y="3" width="3.2" height="7" rx=".8"/><rect x="10.3" y="3" width="3.2" height="5" rx=".8"/>'
P.sync = '<path d="M3 7a5 5 0 0 1 9-2M13 9a5 5 0 0 1-9 2M12 2.5V5H9.5M4 13.5V11h2.5"/>'
P.person = '<circle cx="8" cy="5.5" r="2.5"/><path d="M3.5 13.5c.6-2.6 2.4-4 4.5-4s3.9 1.4 4.5 4"/>'
P.play = '<path d="M5 3.5l7 4.5-7 4.5z"/>'
P.globe = '<circle cx="8" cy="8" r="5.5"/><path d="M2.5 8h11M8 2.5c-2 2-2 9 0 11M8 2.5c2 2 2 9 0 11"/>'
P.box = '<rect x="3" y="3" width="10" height="10" rx="2"/>'

const TREE = '<span style="font-size:15px">🎄</span>'

function projectsSide() {
  const rows = [
    ['🎄', 'Port Geo Lights Cruise', '3 threads · 2 waiting on Zaran', true],
    ['🐻', 'Threadbear', '202 threads'],
    ['P', 'Poddle', '12 threads'],
    ['W', 'Walkies', '8 threads'],
    ['🌐', 'Chrome browser control', '7 threads'],
    ['📷', 'Port Geo calendar 2027', '1 thread'],
    ['🔌', 'Connectors (PlugBear)', '2 threads'],
  ]
  return `<div class="search">${I('search', 's')} Search projects</div>
    <div class="sec">${I('layers', 's')} Projects <span class="ln"></span></div>
    ${rows.map(([a, t, f, sel]) => `<div class="row ${sel ? 'sel' : ''}"><div class="mk"></div><div class="av" style="font-size:${a.length > 1 ? 15 : 13}px">${a}</div><div style="min-width:0"><div class="t">${t}</div><div class="f">${f}</div></div><div class="st"></div></div>`).join('')}`
}

// The page's top, as ProjectPage.swift draws it today, plus `links`.
function pageTop(links = '') {
  return `<div class="head"><div class="av" style="background:none;width:auto">${TREE}</div>Port Geo Lights Cruise<div class="r">${I('more')}</div></div>
  <div class="pg">
    <div class="links">
      <span class="lk">${I('globe', 's')} Live site</span><span class="lk">${I('lock', 's')} Admin</span>${links}
    </div>
    <div class="h">State</div>
    <div class="txt">Entries opened on the live site 30 Oct; voting proposed 4 to 27 Dec. Zaran sends the entrants email once the fixes from Mike's 30 Oct reply are in.</div>`
}

// Port Geo's open items, from the Notion page's checklist and its
// "Who's doing what" table. [title, who, column, extra]
const TASKS = [
  ['Sign artworks, 50 to 60 A0 with QR codes', 'Mike', 'todo'],
  ['Lighting and sign placement instructions', 'Zaran, Tracy', 'todo'],
  ['Captain\'s script for voting on the boat', 'Zaran, Tracy', 'todo'],
  ['Fixes from the 30 Oct reply', 'Mike', 'doing', 'thread'],
  ['Review entries in the admin area', 'Zaran', 'doing'],
  ['Eventbrite link for the tickets page', 'Zaran', 'waiting'],
  ['Who hands out signs at Keel Retreat', 'Zaran', 'waiting'],
  ['Hilton voter prize draw', 'Zaran', 'waiting'],
  ['Entrants email in Mailchimp', 'Zaran', 'waiting'],
  ['Open entries on the website', 'Mike', 'done'],
  ['Agree the voting window', 'Zaran', 'done'],
  ['Winners presentation, 9 Jan', 'Zaran', 'done'],
]
const COLS = [['todo', 'To do'], ['doing', 'Doing'], ['waiting', 'Waiting on someone'], ['done', 'Done']]
