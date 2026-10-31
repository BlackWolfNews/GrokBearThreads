# Builds the option mockups (N-*.html) from the two real turns, then
# render.sh turns them into PNGs. Text is from the threads named in
# README.md, trimmed only where noted.
import pathlib, re
here = pathlib.Path(__file__).parent
bruce = re.sub(r' ?class="DUP\d"', '', (here / '_bruce-msg.html').read_text())

def page(name, size, label, body):
    (here / f'{name}.html').write_text(
        f'<!doctype html><html><head><meta charset="utf-8"><link rel="stylesheet" href="m.css">'
        f'<!-- size: {size} --></head><body><div class="label">{label}</div>{body}</body></html>')

def win(inner):
    return f'<div class="win">{inner}<div class="composer"><span>Message</span><span>↑</span></div></div>'

def card(inner, head='Decision needed'):
    return f'<div class="card" style="margin-top:14px"><div class="head"><span class="hand">✋</span>{head}</div>{inner}</div>'

def btns(*names, sug=0):
    return '<div class="btns">' + ''.join(
        f'<span class="b{" sug" if i == sug else ""}">{n}</span>' for i, n in enumerate(names)) + '<span class="b">Something else…</span></div>'

def rows(items, sug=0):
    out = ''
    for i, (t, d) in enumerate(items):
        pick = '<span class="pick">my pick</span>' if i == sug else ''
        out += f'<div class="row{" sug" if i == sug else ""}"><div class="dot"></div><div><div class="t">{t}{pick}</div><div class="d">{d}</div></div></div>'
    out += '<div class="row own"><div class="dot"></div><div><div class="t">Something else…</div></div></div>'
    return f'<div class="rows">{out}</div>'

PANELS = {}

# ---- Bruce (thread 6fb15afc): a step for Mike ----
FDA = '<code>/Users/bruce/Applications/Threadbear Runner.app</code>'
bruce_report = re.sub(r'<p>I don\'t know what state I left the file picker in\. It may still have a "Go to folder" box open\.</p>\n', '', bruce)

PANELS['bruce', 'A'] = (
    '<div class="work">Worked for 3m 10s<span class="ch">›</span></div>'
    f'<div class="msg">{bruce}</div>'
    '<div class="meta end">32s · $0.22</div>'
    + card(f'<p class="q">On Bruce, add {FDA} to Full Disk Access: press / in the picker, paste the path, then Return, Open, and switch it on.</p>'
           + rows([('Done', 'I run a test thread that lists ~/Documents and check no prompt appears'), ("Go, I've stepped away", 'I do the picker myself; leave the keyboard for a couple of minutes')]),
           head='Decision needed'))

PANELS['bruce', 'B'] = (
    '<div class="work">Worked for 3m 10s<span class="ch">›</span></div>'
    f'<div class="msg">{bruce_report}</div>'
    '<div class="meta end">32s · $0.22</div>'
    + card('<p class="ctx2">The runner has no Full Disk Access yet, so folder prompts can still freeze Bruce\'s threads.</p>'
           f'<ol class="ctx2"><li>In the Full Disk Access picker on Bruce, press / and paste {FDA}</li><li>Return, then Open, then switch it on</li></ol>'
           '<p class="ctx2">If a "Go to folder" box from my typing is still open, close it first.</p>'
           + rows([('Done', 'I run a test thread that lists ~/Documents and check no prompt appears'),
                   ("Go, I've stepped away", 'I do the picker myself; leave the keyboard for a couple of minutes')]),
           head='Decision needed'))

PANELS['bruce', 'C'] = (
    '<div class="work">Worked for 3m 10s<span class="ch">›</span></div>'
    f'<div class="msg">{bruce}</div>'
    '<div class="meta end">32s · $0.22</div>'
    + card(f'<p class="q">On Bruce, add {FDA} to Full Disk Access: press / in the picker, paste the path, then Return, Open, and switch it on.<span class="tip">i</span></p>'
           '<div class="pop">Folder prompts freeze Bruce\'s threads until the runner has it. Once it\'s on I\'ll run a test thread that lists ~/Documents. Close any "Go to folder" box my typing left open first.</div>'
           + btns('Done', "Go, I've stepped away"),
           head='Decision needed'))

# ---- Walkies (thread f6ffb3a1, 31 Oct 12:30): a decision ----
PR = '<a href="#">walkies#52</a>'
walkies_msg = (
    f'<p>The nearby lore requests are back in <code>loreRequests</code>, merged as {PR}. It isn\'t deployed to production yet.</p><ul>'
    '<li><b>Change:</b> a nearby request is now a <code>loreRequests</code> row with <code>nearby: true</code>. The walked-suburb limit counts rows without the flag and the nearby limit counts rows with it, so neither uses up the other\'s allowance.</li>'
    '<li><b>Removed:</b> the <code>loreNearbyRequests</code> table, its cleanup loop, and its two entries in account deletion.</li>'
    '<li><b>Data:</b> production\'s <code>loreNearbyRequests</code> was empty when I checked, so nothing needs moving.</li>'
    '<li><b>Checks:</b> typecheck, lint, and the 56 tests in <code>lore.test.ts</code> and <code>accountDeletion.test.ts</code> pass.</li>'
    '<li>I worked in a throwaway worktree again so the running "Hiding the blue location arrow" thread\'s checkout wasn\'t touched, and removed it afterwards.</li></ul>')
walkies_bullets = (
    '<ul class="sum">'
    f'<li>Nearby lore requests are <code>loreRequests</code> rows with <code>nearby: true</code> again, merged as {PR}</li>'
    '<li>Removed the <code>loreNearbyRequests</code> table; production\'s copy was empty, so nothing to move</li>'
    '<li><a class="w" href="#">Typecheck, lint and 56 lore and account deletion tests pass<span class="g">↑</span></a></li>'
    '<li>Not deployed to production yet: waiting on your go</li></ul>')
open_pr = '<div class="btns"><span class="b pri">Open walkies#52 ↗</span></div>'

PANELS['walkies', 'today'] = (
    '<div class="work">Worked for 2m 7s<span class="ch">›</span></div>'
    f'<div class="msg">{walkies_msg}<p><span class="dup">Until production gets a deploy, it still writes nearby requests to the old table.</span></p></div>'
    '<div class="meta end">2m 7s · $0.53</div>'
    + card('<p class="ctx2">Should I run <code>npx convex deploy</code> to put Walkies main on production (savory-bee-296)? '
           '<span class="dup">Production still has <code>loreNearbyRequests</code> and keeps writing nearby requests there until a deploy.</span> '
           'A deploy sends everything on main, and I haven\'t checked that the earlier merges (#48 to #51) are already on production, so I\'m asking first. '
           'If a nearby row lands before then, the deploy will refuse to drop the table, and I\'d clear that row and try again.</p>'
           + open_pr + btns('Deploy it', "I'll deploy later", "Check what's undeployed first")))

walkies_reply_a = (
    f'<p>The nearby lore requests are back in <code>loreRequests</code>, merged as {PR}, but production (savory-bee-296) hasn\'t had a deploy, so it still writes them to the old <code>loreNearbyRequests</code> table.</p><ul>'
    '<li><b>Change:</b> a nearby request is now a <code>loreRequests</code> row with <code>nearby: true</code>, and each limit counts only its own rows, so neither uses up the other\'s allowance.</li>'
    '<li><b>Removed:</b> the old table, its cleanup loop and its two entries in account deletion. Production\'s copy was empty, so nothing needs moving.</li>'
    '<li><b>Checks:</b> <a class="w" href="#">typecheck, lint and the 56 lore and account deletion tests pass<span class="g">↑</span></a>.</li></ul>'
    '<p>A deploy sends everything on main, and I haven\'t checked that #48 to #51 are already on production.</p>')

PANELS['walkies', 'A'] = (
    '<div class="work">Worked for 2m 7s<span class="ch">›</span></div>'
    f'<div class="msg">{walkies_reply_a}</div>'
    '<div class="meta end">2m 7s · $0.53</div>'
    + card('<p class="q">Deploy Walkies main to production now?</p>' + open_pr
           + rows([('Deploy it', 'If a nearby row lands in the old table first, the deploy won\'t drop it; I clear it and deploy again'),
                   ("Check what's undeployed first", 'I compare production with main and tell you what else would go out'),
                   ("I'll deploy later", 'Production keeps writing to the old table until then')])))

PANELS['walkies', 'B'] = (
    '<div class="work">Worked for 2m 7s<span class="ch">›</span></div>'
    f'<div class="msg">{walkies_bullets}</div>'
    '<div class="meta end">2m 7s · $0.53</div>'
    + card('<p class="ctx2">Production (savory-bee-296) still writes nearby requests to the old <code>loreNearbyRequests</code> table until it gets a deploy. '
           'A deploy sends everything on main, and I haven\'t checked that #48 to #51 are already there.</p>'
           '<p class="q">Deploy Walkies main to production now?</p>' + open_pr
           + rows([('Deploy it', 'If a nearby row lands in the old table first, the deploy won\'t drop it; I clear it and deploy again'),
                   ("Check what's undeployed first", 'I compare production with main and tell you what else would go out'),
                   ("I'll deploy later", 'Production keeps writing to the old table until then')])))

PANELS['walkies', 'C'] = (
    '<div class="work">Worked for 2m 7s<span class="ch">›</span></div>'
    f'<div class="msg">{walkies_msg}<p>Until production gets a deploy, it still writes nearby requests to the old table.</p></div>'
    '<div class="meta end">2m 7s · $0.53</div>'
    + card('<p class="q">Deploy Walkies main to production (savory-bee-296) now?<span class="tip">i</span></p>'
           '<div class="pop">A deploy sends everything on main, and I haven\'t checked that #48 to #51 are already there. If a nearby row lands in the old table first, the deploy won\'t drop it; I\'d clear it and try again.</div>'
           + open_pr + btns('Deploy it', "I'll deploy later", "Check what's undeployed first")))


# ---- C: brief first, the full reply a click away (Codex desktop) ----
walkies_rows = rows([('Deploy it', 'If a nearby row lands in the old table first, the deploy won\'t drop it; I clear it and deploy again'),
                     ("Check what's undeployed first", 'I compare production with main and tell you what else would go out'),
                     ("I'll deploy later", 'Production keeps writing to the old table until then')])
PANELS['walkies', 'C'] = (
    '<div class="work">Worked for 2m 7s<span class="ch">›</span></div>'
    '<div class="msg"><ul class="sum">'
    f'<li>Nearby lore requests are <code>loreRequests</code> rows with <code>nearby: true</code> again, merged as {PR}</li>'
    '<li>Removed the <code>loreNearbyRequests</code> table; production\'s copy was empty, so nothing to move</li>'
    '<li><a class="w" href="#">Typecheck, lint and 56 lore and account deletion tests pass<span class="g">↑</span></a></li>'
    '<li>Not deployed: production still writes to the old table, and a deploy also sends #48 to #51</li></ul>'
    '<span class="more">Full reply ›<span class="n">6 lines</span></span></div>'
    '<div class="meta end">2m 7s · $0.53</div>'
    + card('<p class="q">Deploy Walkies main to production now?</p>' + open_pr + walkies_rows))
PANELS['bruce', 'C'] = (
    '<div class="work">Worked for 3m 10s<span class="ch">›</span></div>'
    '<div class="msg"><ul class="sum">'
    '<li>The malware popup was an old, revoked copy of <code>codex</code>; I deleted it, and Done just closes the popup</li>'
    '<li>The runner is in Bruce\'s own Applications folder, so the picker at <code>/Applications</code> doesn\'t show it</li>'
    '<li>The permission you allowed only covers Downloads and removable drives; Full Disk Access isn\'t on yet</li>'
    '<li><code>run.sh</code> is Sammy Cam\'s backend; I didn\'t look into "Device Added to Your Account"</li></ul>'
    '<span class="more">Full reply ›<span class="n">18 lines</span></span></div>'
    '<div class="meta end">32s · $0.22</div>'
    + card(f'<p class="q">On Bruce, add {FDA} to Full Disk Access: press / in the picker, paste the path, then Return, Open, and switch it on.</p>'
           + rows([('Done', 'I run a test thread that lists ~/Documents and check no prompt appears'), ("Go, I've stepped away", 'I do the picker myself; leave the keyboard for a couple of minutes')])))

# ---- pages ----
SIZES = {'today': '1000x1770', 'A': '1000x1760', 'B': '1000x1780', 'C': '1000x1460'}
TODAY_BRUCE = (here / '_today-bruce.html').read_text().split('<div class="win">', 1)[1].rsplit('<div class="composer">', 1)[0]
OPTIONS = {
    'today': ('0-today', 'TODAY · repeated words in red · Walkies (f6ffb3a1) above, Bruce (6fb15afc, message trimmed to fit) below'),
    'A': ('1-reply-explains', 'A · THE REPLY EXPLAINS, THE CARD ASKS'),
    'B': ('2-card-decides', 'B · BULLETS REPORT, THE CARD HOLDS THE DECISION'),
    'C': ('3-brief-first', 'C · BRIEF FIRST, THE FULL REPLY ONE CLICK AWAY'),
}
for key, (name, label) in OPTIONS.items():
    bruce_inner = TODAY_BRUCE if key == 'today' else PANELS['bruce', key]
    body = (f'<div class="panel">{win(PANELS["walkies", key])}</div>'
            f'<div class="panel">{win(bruce_inner)}</div>')
    page(name, SIZES[key], label, body)
print('built')
