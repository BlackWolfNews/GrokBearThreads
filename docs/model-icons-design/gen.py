# Writes one picker mockup per icon idea (N-*.html); render.sh turns them into PNGs.
import math
SW = 1.7  # line weight on the 24 grid, like Bear.swift

def head(cx, cy, r, ear=None, shut=False, extra="", sw=None):
    SW = sw or globals()['SW']
    ear = ear or r * 0.4
    ex, ey = r * 0.72, r * 0.72
    s = ""
    for sx in (-1, 1):
        s += f'<circle cx="{cx+sx*ex:.2f}" cy="{cy-ey:.2f}" r="{ear:.2f}" fill="var(--bg)" stroke="currentColor" stroke-width="{SW}"/>'
    s += f'<circle cx="{cx}" cy="{cy}" r="{r}" fill="var(--bg)" stroke="currentColor" stroke-width="{SW}"/>'
    er = max(0.7, r * 0.13)
    for sx in (-1, 1):
        if shut:
            s += f'<path d="M{cx+sx*r*0.38-er*1.4:.2f} {cy-r*0.12:.2f} q{er*1.4:.2f} {er*1.2:.2f} {er*2.8:.2f} 0" fill="none" stroke="currentColor" stroke-width="{SW*0.8}" stroke-linecap="round"/>'
        else:
            s += f'<circle cx="{cx+sx*r*0.38:.2f}" cy="{cy-r*0.12:.2f}" r="{er:.2f}" fill="currentColor"/>'
    s += f'<ellipse cx="{cx}" cy="{cy+r*0.3:.2f}" rx="{r*0.17:.2f}" ry="{r*0.12:.2f}" fill="currentColor"/>'
    return s + extra

def svg(inner, size=28, cls=""):
    return f'<svg class="ic {cls}" width="{size}" height="{size}" viewBox="0 0 24 24" stroke-linecap="round" stroke-linejoin="round">{inner}</svg>'

L = f'fill="none" stroke="currentColor" stroke-width="{SW}" stroke-linecap="round" stroke-linejoin="round"'

# --- A: the three bears, by size
A = {
    "Opus":   head(12, 13.5, 8.2),
    "Sonnet": head(12, 14.5, 6.6),
    "Haiku":  head(12, 15.5, 4.8, ear=2.6),
    "Fable":  head(11, 14, 7.2) + '<path d="M20 1.5 q.4 2.6 3 3 q-2.6 .4 -3 3 q-.4 -2.6 -3 -3 q2.6 -.4 3 -3 Z" fill="currentColor"/>',
}
# --- B: one bear, a prop per model
B = {
    "Opus":   head(10, 14, 6.4) + f'<circle cx="18.2" cy="6.2" r="2.3" {L}/><circle cx="16" cy="10" r="0.9" fill="currentColor"/>',
    "Sonnet": head(10, 14, 6.4) + f'<path d="M18 9.5 v-6 l3 -1 M18 9.5 a1.4 1.2 0 1 1 -0.1 0" {L}/>',
    "Haiku":  head(13, 14, 6.4) + f'<path d="M2 10 h3.5 M1.5 14 h3 M2 18 h3.5" {L}/>',
    "Fable":  head(12, 14.5, 6.4) + f'<path d="M7 7.5 L12 1.5 L17 7.5 Z" fill="var(--bg)" stroke="currentColor" stroke-width="{SW}" stroke-linejoin="round"/><circle cx="12.6" cy="5" r="0.7" fill="currentColor"/>',
}
# --- C: honey pots, fuller for the bigger model
def pot(level, star=False):
    top, bot = 7.5, 20.5
    y = bot - (bot - top) * level
    s = f'<clipPath id="p{int(level*100)}{int(star)}"><path d="M6 7.5 h12 c1.5 3 1.5 10 -1 13 h-10 c-2.5 -3 -2.5 -10 -1 -13 Z"/></clipPath>'
    s += f'<rect x="3" y="{y:.2f}" width="18" height="{bot-y+1:.2f}" fill="currentColor" opacity="0.35" clip-path="url(#p{int(level*100)}{int(star)})"/>'
    s += f'<path d="M6 7.5 h12 c1.5 3 1.5 10 -1 13 h-10 c-2.5 -3 -2.5 -10 -1 -13 Z" {L}/><path d="M5 7.5 h14 M7 4.5 h10 v3 h-10 Z" {L}/>'
    if star: s += f'<path d="M12 11 l1 2 2.2 .3 -1.6 1.5 .4 2.2 -2 -1.1 -2 1.1 .4 -2.2 -1.6 -1.5 2.2 -.3 Z" fill="currentColor" stroke="none"/>'
    return s
C = {"Opus": pot(0.9), "Sonnet": pot(0.55), "Haiku": pot(0.25), "Fable": pot(0.9, star=True)}

def rail_heads(n, sel):
    # a little head per login in the pool, so "3" reads at a glance
    xs = {1: [12], 2: [8.5, 15.5], 3: [5.5, 12, 18.5]}[n]
    return svg("".join(head(x, 13.5, 3.3, ear=1.4, sw=1.1) for x in xs), size=40)

def rail_prop(kind):
    if kind == "Claude": return svg(head(12, 13.5, 7) , size=34)
    if kind == "ConvexClaude": return svg(head(12, 14.5, 6.6) + f'<path d="M7.5 6.8 q4.5 -5 9 0" {L}/><path d="M6 7 h12" {L}/>', size=34)
    return svg(head(12, 13.5, 7) + f'<path d="M8.8 18.2 l-1.6 1.4 1.6 1.4 M15.2 18.2 l1.6 1.4 -1.6 1.4" {L}/>', size=34)

MODELS = [("Opus 5.5","Opus","For complex work and everyday tasks",False,True),
          ("Sonnet 5.5","Sonnet","Most efficient for simpler tasks",False,False),
          ("Haiku 5.5","Haiku","Fastest for quick answers",False,False),
          ("Fable 5.1","Fable","For your toughest challenges",True,False),
          ("Haiku 4.5","Haiku","Fastest for quick answers",True,False),
          ("Sonnet 5","Sonnet","Efficient for routine tasks",True,False)]
POOLS = [("Claude","3 · 75%",3),("ConvexClaude","1 · 100%",1),("Codex","1 · 79%",1)]

CSS = """
:root{--bg:#2b2b2e}
body{margin:0;background:#1d1d1f;font:13px -apple-system,BlinkMacSystemFont,"SF Pro Text",sans-serif;color:#ececee;display:flex;flex-direction:column;align-items:center;padding-top:20px}
.close{display:flex;gap:34px;margin-top:22px;color:#d6d6da;--bg:#1d1d1f}.close div{display:flex;flex-direction:column;align-items:center;gap:4px;font-size:11px;color:#8b8b90}.close div .ic{color:#e0e0e4}
.close .ic[width='40'],.close .ic[width='34']{width:72px;height:72px}
.pop{width:470px;background:var(--bg);border:1px solid #444;border-radius:16px;display:flex;overflow:hidden;box-shadow:0 20px 50px #0008}
.rail{width:112px;border-right:1px solid #3d3d40;padding:6px;display:flex;flex-direction:column;gap:2px}
.pool{border-radius:9px;padding:8px 4px;text-align:center;color:#a8a8ad}
.pool.sel{background:#3a3a3e;color:#fff}
.pool .t{font-size:12.5px}.pool .s{font-size:11px;color:#8b8b90;margin-top:1px}
.pool .ic{display:block;margin:0 auto 3px}
.col{flex:1}
.search{height:38px;display:flex;align-items:center;gap:7px;padding:0 12px;border-bottom:1px solid #3d3d40;color:#77777c}
.list{padding:6px}
.h{font-size:11px;color:#77777c;padding:8px 10px 3px}
.row{display:flex;align-items:center;gap:10px;padding:6px 10px;border-radius:8px}
.row .ic{flex:none;color:#d6d6da}
.row.old .ic{color:#8b8b90}
.row .n{font-weight:600;font-size:13.5px}.row .d{font-size:11.5px;color:#9a9aa0}
.row .tick{margin-left:auto;color:#ddd;font-size:13px}
.eff{border-top:1px solid #3d3d40;padding:10px 12px}
.seg{display:flex;background:#ffffff0d;border-radius:8px;padding:2px}
.seg span{flex:1;text-align:center;padding:4px 0;border-radius:6px;color:#b8b8bd;font-size:12px}
.seg span.on{background:#1f1f22;color:#fff;font-weight:600}
"""

def page(name, icons, rail):
    rows, older = [], False
    for title, key, desc, old, sel in MODELS:
        if old and not older:
            rows.append('<div class="h">Older</div>'); older = True
        ic = svg(icons[key]) if icons else ""
        rows.append(f'<div class="row{" old" if old else ""}">{ic}<div><div class="n">{title}</div><div class="d">{desc}</div></div>{"<span class=tick>★ ✓</span>" if sel else ""}</div>')
    keys = ["Opus", "Sonnet", "Haiku", "Fable"]
    closeup = "".join(f'<div>{svg(icons[k], size=72)}<span>{k}</span></div>' for k in keys) if icons else "".join(f'<div>{rail(t, n)}<span>{t}</span></div>' for t, s_, n in POOLS)
    pools = "".join(f'<div class="pool{" sel" if i==0 else ""}">{rail(t,n) if rail else ""}<div class="t">{t}</div><div class="s">{s}</div></div>' for i,(t,s,n) in enumerate(POOLS))
    html = f'''<!doctype html><!-- size: 560x530 --><html><head><meta charset="utf-8"><style>{CSS}</style></head><body>
<div class="pop"><div class="rail">{pools}</div><div class="col">
<div class="search">⌕ <span>Search models</span></div><div class="list">{"".join(rows)}</div>
<div class="eff"><div class="seg"><span>Low</span><span class="on">Medium</span><span>High</span><span>Extra high</span><span>Max</span></div></div>
</div></div>
<div class="close">{closeup}</div></body></html>'''
    open(name, "w").write(html)

page("1-three-bears.html", A, lambda t, n: rail_heads(n, False))
page("2-bear-props.html", B, lambda t, n: rail_prop(t))
page("3-honey-pots.html", C, lambda t, n: rail_heads(n, False))
