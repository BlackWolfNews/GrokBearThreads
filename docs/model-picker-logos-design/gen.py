# Mockups for the model picker with provider logos (5 Nov 2026).
import re, pathlib
here = pathlib.Path(__file__).parent
def inner(n):
    s = (here / f"{n}.svg").read_text()
    return re.search(r"<svg[^>]*>(.*)</svg>", s, re.S).group(1)
LOGO = {"claude": inner("anthropic"), "codex": inner("codex")}
def logo(p, size=16, cls="logo"):
    return f'<svg class="{cls}" viewBox="0 0 24 24" width="{size}" height="{size}" fill="currentColor" fill-rule="evenodd">{LOGO[p]}</svg>'

POOLS = [("Claude", "claude", "3 · 100%", 3), ("ConvexClaude", "claude", "1 · 100%", 1), ("Codex", "codex", "1 · 97%", 1)]
MODELS = [("GPT-6.1-Sol", "Latest workhorse model for coding and agents", True, True),
          ("GPT-6-Astra", "Frontier intelligence for the most demanding work", False, False),
          ("GPT-6.1 Terra", "GPT-6.1 Terra Codex model", False, False),
          ("GPT-6-Luna", "Fast and affordable model for easier tasks", False, False)]
OLDER = [("GPT-6-Sol", "Previous generation workhorse model"),
         ("GPT-5.6-Sol", "Older generation workhorse model"),
         ("GPT-5.6-Terra", "Older balanced model for straightforward tasks")]

CSS = """
body{margin:0;background:#1c1c1e;font:13px -apple-system,BlinkMacSystemFont,'SF Pro Text',sans-serif;color:#f2f2f7;padding:28px}
.pop{display:flex;width:var(--w);border-radius:14px;overflow:hidden;background:rgba(48,44,46,.96);
 box-shadow:0 0 0 .5px rgba(255,255,255,.14),0 18px 50px rgba(0,0,0,.55)}
.rail{width:var(--rw);background:rgba(255,255,255,.03);border-right:.5px solid rgba(255,255,255,.1);padding:6px 6px;display:flex;flex-direction:column;gap:4px}
.main{flex:1;display:flex;flex-direction:column;min-width:0}
.search{height:38px;display:flex;align-items:center;gap:7px;padding:0 12px;border-bottom:.5px solid rgba(255,255,255,.1);color:rgba(235,235,245,.35)}
.list{padding:6px}
.row{display:flex;align-items:center;gap:10px;padding:6px 10px;border-radius:7px}
.row .t{font-weight:500}.row .s{font-size:11px;color:rgba(235,235,245,.55);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.row .txt{flex:1;min-width:0}
.row.hover{background:rgba(255,255,255,.06)}
.row.sel{background:rgba(255,255,255,.1)}
.tick{width:12px;text-align:center;font-size:12px;font-weight:600}
.star{font-size:9px;color:rgba(235,235,245,.3)}
.h{font-size:11px;font-weight:500;color:rgba(235,235,245,.3);padding:8px 10px 2px}
.effort{border-top:.5px solid rgba(255,255,255,.1);padding:8px 10px}
.seg{display:flex;background:rgba(255,255,255,.05);border-radius:8px;padding:2px}
.seg div{flex:1;text-align:center;padding:5px 0;border-radius:6px;color:rgba(235,235,245,.6)}
.seg .on{background:#1c1c1e;color:#fff;font-weight:600;box-shadow:0 1px 2px rgba(0,0,0,.4)}
.pool{border-radius:8px;padding:7px 4px;text-align:center;color:rgba(235,235,245,.6)}
.pool.on{background:rgba(255,255,255,.1);color:#fff}
.pool .n{font-size:12px;margin-top:4px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.pool .c{font-size:10.5px;color:rgba(235,235,245,.35);font-variant-numeric:tabular-nums}
.tile{width:26px;height:26px;border-radius:7px;display:flex;align-items:center;justify-content:center;background:rgba(255,255,255,.07);color:rgba(235,235,245,.75);flex:none}
.sq{position:relative;width:40px;height:40px;border-radius:10px;display:flex;align-items:center;justify-content:center;color:rgba(235,235,245,.55);margin:0 auto}
.sq.on{background:rgba(255,255,255,.12);color:#fff}
.badge{position:absolute;right:1px;bottom:1px;font-size:9.5px;font-weight:600;min-width:14px;height:14px;border-radius:7px;background:#3a3a3c;color:rgba(235,235,245,.8);display:flex;align-items:center;justify-content:center;padding:0 3px;box-sizing:border-box}
.head{display:flex;align-items:center;gap:8px;padding:10px 12px 8px;border-bottom:.5px solid rgba(255,255,255,.1)}
.head .t{font-weight:600}.head .s{font-size:11px;color:rgba(235,235,245,.45);margin-left:auto;font-variant-numeric:tabular-nums}
.chip{margin-top:12px;margin-left:calc(var(--rw) + 20px);color:rgba(235,235,245,.7);display:flex;gap:6px;align-items:center}
"""
SEARCH = '<div class="search">⌕ Search models</div>'
def effort():
    return '<div class="effort"><div class="seg">' + "".join(f'<div class="{"on" if l=="High" else ""}">{l}</div>' for l in ["Low","Medium","High","Extra high","Max"]) + "</div></div>"

def rows(icon, selstyle):
    out = []
    for i, (t, s, dflt, sel) in enumerate(MODELS):
        cls = "row" + (" sel" if sel and selstyle == "fill" else "") + (" hover" if i == 1 else "")
        ic = f'<div class="tile">{logo("codex",15)}</div>' if icon else ""
        star = '<span class="star">★</span>' if dflt else ""
        tick = f'<span class="tick">{"✓" if sel and selstyle=="tick" else ""}</span>' if selstyle == "tick" else ""
        out.append(f'<div class="{cls}">{ic}<div class="txt"><div class="t">{t}</div><div class="s">{s}</div></div>{star}{tick}</div>')
    out.append('<div class="h">Older</div>')
    for t, s in OLDER:
        ic = f'<div class="tile" style="opacity:.55">{logo("codex",15)}</div>' if icon else ""
        out.append(f'<div class="row">{ic}<div class="txt"><div class="t" style="color:rgba(235,235,245,.75)">{t}</div><div class="s">{s}</div></div>{"<span class=tick></span>" if selstyle=="tick" else ""}</div>')
    return '<div class="list">' + "".join(out) + "</div>"

def rail_named():
    return "".join(f'<div class="pool{" on" if n=="Codex" else ""}">{logo(p,17)}<div class="n">{n}</div><div class="c">{c}</div></div>' for n,p,c,_ in POOLS)

def page(name, w, rw, rail, main):
    html = f"<!doctype html><meta charset=utf-8><style>{CSS}</style><body><div class='pop' style='--w:{w}px;--rw:{rw}px'><div class='rail'>{rail}</div><div class='main'>{main}</div></div></body>"
    (here / name).write_text(html)

# A: logos in the rail, rows are just words
page("A-rail-logos.html", 440, 96, rail_named(), SEARCH + rows(False, "tick") + effort())
# B: the logo on every row too, the chosen row filled instead of ticked
page("B-row-logos.html", 460, 96, rail_named(), SEARCH + rows(True, "fill") + effort())
# C: a slim rail of logo tiles with login counts; the pool's name heads the list
rail_c = "".join(f'<div class="sq{" on" if n=="Codex" else ""}">{logo(p,19)}<span class="badge">{k}</span></div>' for n,p,c,k in POOLS)
head = f'<div class="head">{logo("codex",15)}<span class="t">Codex</span><span class="s">1 login · 97% left</span></div>'
page("C-slim-rail.html", 400, 54, rail_c, head + SEARCH + rows(False, "tick") + effort())
