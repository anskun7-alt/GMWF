"""
GMWF PDF KIT — reusable building blocks.

Every function returns an HTML string. Documents are made of pages;
each page is a list of these blocks joined together.

    from kit import *
    p1 = hero(...) + h2("Morning", "صبح") + steps(step(1, "Do this"), ...)
    build_pdf(meta, [p1, p2], "out/my-guide.pdf")
"""
import os, html, pathlib

KIT_DIR = pathlib.Path(__file__).parent.resolve()
ORG_EN = "Gulzar Madina Welfare Foundation"
ORG_UR = "گلزار مدینہ ویلفیئر فاؤنڈیشن"

# ---------- Icons (24x24, stroke style) ----------
_I = {
 "check":'<path d="M5 12.5l4.5 4.5L19 7.5"/>',
 "x":'<path d="M6 6l12 12M18 6L6 18"/>',
 "alert":'<path d="M12 3.5l9.5 16.5h-19z"/><path d="M12 10v4.5"/><path d="M12 17.4v.2"/>',
 "clock":'<circle cx="12" cy="12" r="9"/><path d="M12 7v5.5l3.5 2"/>',
 "barcode":'<path d="M4 5v14M7 5v14M10.5 5v14M13 5v14M16 5v14M20 5v14"/>',
 "pill":'<g transform="rotate(-40 12 12)"><rect x="2.5" y="8" width="19" height="8" rx="4"/><path d="M12 8v8"/></g>',
 "box":'<path d="M3.5 8l8.5-4.5L20.5 8v8.5L12 21l-8.5-4.5z"/><path d="M3.5 8l8.5 4.5L20.5 8M12 12.5V21"/>',
 "lock":'<rect x="5" y="11" width="14" height="9" rx="2"/><path d="M8 11V8a4 4 0 018 0v3"/>',
 "pencil":'<path d="M4 20l1-4L16.5 4.5a2 2 0 013 3L8 19z"/><path d="M14.5 6.5l3 3"/>',
 "calendar":'<rect x="3.5" y="5" width="17" height="15" rx="2"/><path d="M3.5 10h17M8 3v4M16 3v4"/>',
 "clipboard":'<rect x="6" y="4.5" width="12" height="16" rx="2"/><path d="M9 4.5h6v3H9zM9 12h6M9 15.5h6"/>',
 "users":'<circle cx="9" cy="8" r="3"/><path d="M3.5 19c0-3 2.5-5 5.5-5s5.5 2 5.5 5"/><circle cx="17" cy="9" r="2.3"/><path d="M16.5 14c2.5 0 4 1.5 4 4"/>',
 "arrow":'<path d="M5 12h14M13 6l6 6-6 6"/>',
 "sun":'<circle cx="12" cy="12" r="4"/><path d="M12 2.5v2.5M12 19v2.5M2.5 12H5M19 12h2.5M5.3 5.3l1.8 1.8M16.9 16.9l1.8 1.8M5.3 18.7l1.8-1.8M16.9 7.1l1.8-1.8"/>',
 "moon":'<path d="M20 14.5A8 8 0 019.5 4a8 8 0 1010.5 10.5z"/>',
 "plus":'<path d="M12 5v14M5 12h14"/>',
 "minus":'<path d="M5 12h14"/>',
 "pot":'<path d="M5 10h14v6a4 4 0 01-4 4H9a4 4 0 01-4-4z"/><path d="M3.5 10h17M9 7c0-1.5 1-1.5 1-3M14 7c0-1.5 1-1.5 1-3"/>',
 "shield":'<path d="M12 3l8 3v6c0 4.5-3.2 7.8-8 9-4.8-1.2-8-4.5-8-9V6z"/><path d="M8.8 12l2.4 2.4 4-4.4"/>',
 "layers":'<path d="M12 3l9 5-9 5-9-5z"/><path d="M3 12.5l9 5 9-5M3 16.5l9 5 9-5"/>',
 "file":'<path d="M6 3.5h8l4 4V20.5H6z"/><path d="M14 3.5v4h4M9 12h6M9 15.5h6"/>',
 "search":'<circle cx="11" cy="11" r="6.5"/><path d="M16 16l4.5 4.5"/>',
 "trash":'<path d="M4 7h16M9 7V4.5h6V7M6.5 7l1 13h9l1-13"/>',
 "ban":'<circle cx="12" cy="12" r="9"/><path d="M5.6 5.6l12.8 12.8"/>',
 "user":'<circle cx="12" cy="8" r="3.6"/><path d="M4.5 20c0-4 3.4-6.5 7.5-6.5s7.5 2.5 7.5 6.5"/>',
 "star":'<path d="M12 3.5l2.6 5.4 5.9.8-4.3 4.1 1 5.9L12 17l-5.2 2.7 1-5.9-4.3-4.1 5.9-.8z"/>',
 "book":'<path d="M4 5.5c3-1 5.5-.8 8 1 2.5-1.8 5-2 8-1V19c-3-1-5.5-.8-8 1-2.5-1.8-5-2-8-1z"/><path d="M12 6.5V20"/>',
 "eye":'<path d="M2.5 12S6 5.5 12 5.5 21.5 12 21.5 12 18 18.5 12 18.5 2.5 12 2.5 12z"/><circle cx="12" cy="12" r="3"/>',
 "list":'<path d="M8.5 6.5H20M8.5 12H20M8.5 17.5H20"/><path d="M4 6.5h.1M4 12h.1M4 17.5h.1"/>',
 "sync":'<path d="M4.5 12a7.5 7.5 0 0113-5l2 2M19.5 12a7.5 7.5 0 01-13 5l-2-2"/><path d="M19.5 4v5h-5M4.5 20v-5h5"/>',
 "palette":'<path d="M12 3.5a8.5 8.5 0 100 17c1.5 0 2-1 1.4-2-.6-1 0-2.2 1.3-2.2H17a3.5 3.5 0 003.5-3.5C20.5 7.5 16.7 3.5 12 3.5z"/><path d="M7.5 11h.1M10 7.5h.1M14.5 7.5h.1"/>',
 "type":'<path d="M5 6.5V5h14v1.5M12 5v14M9 19h6"/>',
 "grid":'<rect x="4" y="4" width="7" height="7" rx="1.5"/><rect x="13" y="4" width="7" height="7" rx="1.5"/><rect x="4" y="13" width="7" height="7" rx="1.5"/><rect x="13" y="13" width="7" height="7" rx="1.5"/>',
}

def ic(name, size=5, color="currentColor", sw=2.2):
    return (f'<svg width="{size}mm" height="{size}mm" viewBox="0 0 24 24" fill="none" stroke="{color}" '
            f'stroke-width="{sw}" stroke-linecap="round" stroke-linejoin="round" style="flex:none;vertical-align:middle">{_I[name]}</svg>')

# ---------- Inline helpers ----------
def lbl(t):  return f'<span class="lbl">{t}</span>'
def code(t): return f'<span class="code">{t}</span>'
def btn(t, kind="", icon=None):
    i = ic(icon, 3.4, sw=2.6) if icon else ""
    return f'<span class="btn {kind}">{i}{t}</span>'
def badge(t, kind="grey"): return f'<span class="badge {kind}">{t}</span>'
def yn(v):
    return (f'<span class="yes">{ic("check",3.6,"#fff",3)}</span>' if v
            else f'<span class="no">{ic("x",3.2,"#8A958F",3)}</span>')
def b(t): return f"<b>{t}</b>"
def ur(t, cls="ur"): return f'<div class="{cls}" dir="rtl">{t}</div>'
def u(t): return ur(t, "u")

# ---------- Blocks ----------
def hero(kicker, title, lead_en=None, lead_ur=None):
    s = f'<div class="hero"><span class="kicker">{kicker}</span><h1>{title}</h1>'
    if lead_en: s += f'<p class="lead">{lead_en}</p>'
    if lead_ur: s += ur(lead_ur)
    return s + '</div>'

def h2(en, urdu=None, rtl=False):
    right = f'<span class="h2ur">{urdu}</span>' if urdu else ""
    return f'<h2><span class="bar"></span><span>{en}</span>{right}</h2>'

def step(n, en, urdu=None, sub=None, gold=False, extra=""):
    s = f'<div class="step"><div class="num{" gold" if gold else ""}">{n}</div><div class="sc"><div class="en">{en}</div>'
    if sub: s += f'<div class="sub">{sub}</div>'
    if urdu: s += ur(urdu)
    return s + extra + '</div></div>'
def steps(*items): return '<div class="steps">' + "".join(items) + '</div>'

def ustep(n, urdu, en=None, gold=False, extra=""):
    """Urdu-first step (for fully Urdu documents)."""
    s = f'<div class="step"><div class="num{" gold" if gold else ""}">{n}</div><div class="sc">{u(urdu)}'
    if en: s += f'<div class="sub" dir="ltr" style="text-align:right">{en}</div>'
    return s + extra + '</div></div>'

def check(en, urdu=None, sub=None):
    s = f'<div class="chk"><div class="box"></div><div class="sc"><div class="en">{en}</div>'
    if sub: s += f'<div class="sub">{sub}</div>'
    if urdu: s += ur(urdu)
    return s + '</div></div>'

def uchk(urdu, en=None):
    s = f'<div class="chk"><div class="box"></div><div class="sc">{u(urdu)}'
    if en: s += f'<div class="sub" dir="ltr" style="text-align:right">{en}</div>'
    return s + '</div></div>'

_CO_ICON = {"stop":"ban","warn":"alert","tip":"eye","ok":"check","rule":"shield"}
def callout(kind, title, body="", urdu_title=None, urdu_body=None, rtl=False):
    t = f'<div class="t">{title}</div>' if title else ""
    x = f'<div class="x">{body}</div>' if body else ""
    uu = ""
    if urdu_title or urdu_body:
        uu = ur((f"<b>{urdu_title}</b> " if urdu_title else "") + (urdu_body or ""))
    return (f'<div class="co {kind}"><div class="ico">{ic(_CO_ICON[kind],5,"#fff",2.4)}</div>'
            f'<div style="flex:1;min-width:0">{t}{x}{uu}</div></div>')

def ucallout(kind, urdu_title, urdu_body=""):
    return (f'<div class="co {kind}"><div class="ico">{ic(_CO_ICON[kind],5,"#fff",2.4)}</div>'
            f'<div style="flex:1;min-width:0">{u("<b>"+urdu_title+"</b> "+urdu_body)}</div></div>')

def card(title, body, icon="box", tone="", num=None, eg=None, urdu=None):
    n = f'<div class="cn">{num}</div>' if num else ""
    e = f'<div class="eg">{eg}</div>' if eg else ""
    uu = ur(urdu) if urdu else ""
    return (f'<div class="card"><div class="top"><div class="ci {tone}">{ic(icon,5)}</div>'
            f'<div>{n}<div class="ct">{title}</div></div></div><p>{body}</p>{uu}{e}</div>')

def ucard(title, urdu_body, icon="box", tone="", num=None, eg=None):
    n = f'<div class="cn">{num}</div>' if num else ""
    e = f'<div class="eg" dir="rtl" style="text-align:right">{eg}</div>' if eg else ""
    return (f'<div class="card"><div class="top"><div class="ci {tone}">{ic(icon,5)}</div>'
            f'<div style="flex:1">{n}<div class="ct nq" dir="rtl" style="text-align:right;line-height:1.9;font-size:12pt">{title}</div></div></div>'
            f'{u(urdu_body)}{e}</div>')

def grid(cols, *items): return f'<div class="grid{cols}">' + "".join(items) + '</div>'

def dodont(do_title, dos, dont_title, donts):
    """dos / donts: list of (english, urdu_or_None)"""
    def li(icn, col, e, uu):
        return f'<li>{ic(icn,4,col,3)}<div>{e}{ur(uu) if uu else ""}</div></li>'
    d = "".join(li("check", "#1E8E4E", e, uu) for e, uu in dos)
    n = "".join(li("x", "#C0272D", e, uu) for e, uu in donts)
    return (f'<div class="dd"><div class="do"><h4>{ic("check",4.4,"#1E8E4E",3)}{do_title}</h4><ul>{d}</ul></div>'
            f'<div class="dont"><h4>{ic("x",4.4,"#C0272D",3)}{dont_title}</h4><ul>{n}</ul></div></div>')

def fig(img, pins=(), caption=None, width="100%", img_dir="img"):
    ps = "".join(f'<div class="pin" style="left:{x}%;top:{y}%">{n}</div>' for n, x, y in pins)
    c = f'<div class="cap">{caption}</div>' if caption else ""
    return f'<div style="width:{width}"><div class="fig"><img src="../kit/{img_dir}/{img}">{ps}</div>{c}</div>'

def legend(*items):
    """items: (n, english, urdu_or_None)"""
    r = "".join(f'<div class="li"><div class="pn">{n}</div><div>{e}{ur(uu) if uu else ""}</div></div>' for n, e, uu in [(i + (None,))[:3] for i in items])
    return f'<div class="legend">{r}</div>'

def table(headers, rows, cls="tbl", centers=()):
    th = "".join(f'<th class="{"c" if i in centers else ""}">{h}</th>' for i, h in enumerate(headers))
    tr = "".join("<tr>" + "".join(f'<td class="{"c" if i in centers else ""}">{c}</td>' for i, c in enumerate(r)) + "</tr>" for r in rows)
    return f'<table class="{cls}"><thead><tr>{th}</tr></thead><tbody>{tr}</tbody></table>'

def flow(*boxes):
    out = []
    for i, bx in enumerate(boxes):
        if i: out.append(f'<div class="fa">{ic("arrow",6,"#146C43",2.6)}</div>')
        out.append(f'<div class="fb">{bx}</div>')
    return '<div class="flow">' + "".join(out) + '</div>'

def bar(pct): return f'<div class="bar-o"><i style="width:{pct}%"></i></div>'

# ---------- Page wrapper & PDF build ----------
def _page(inner, meta, n, total, rtl):
    org = ORG_UR if rtl else ORG_EN
    orgstyle = ' style="font-family:Nastaliq,Inter;line-height:1.7;font-size:15pt"' if rtl else ""
    ver = f'{meta["version_line"]}'
    return f'''<section class="page{" rtl" if rtl else ""}">
<header class="hdr"><div class="logo"><img src="../kit/img/logo.png"></div>
<div class="org"><b{orgstyle}>{org}</b><span>{meta["dept"]}</span></div>
<div class="meta"><b>{meta["ref"]}</b><br>{ver}<br><span class="tag">{meta["tag"]}</span></div></header>
<main class="body">{inner}</main>
<footer class="ftr"><span><b>GMWF</b> · {meta["short"]}</span><span>{"صفحہ" if rtl else "Page"} {n} / {total}</span></footer>
</section>'''

def build_pdf(meta, pages, out_pdf, rtl=False, html_dir=None):
    from playwright.sync_api import sync_playwright
    html_dir = pathlib.Path(html_dir or (KIT_DIR.parent / "build")); html_dir.mkdir(exist_ok=True)
    total = len(pages)
    body = "\n".join(_page(p, meta, i + 1, total, rtl) for i, p in enumerate(pages))
    doc = (f'<!doctype html><html lang="{"ur" if rtl else "en"}" dir="{"rtl" if rtl else "ltr"}"><head><meta charset="utf-8">'
           f'<title>{html.escape(meta["title"])}</title><link rel="stylesheet" href="../kit/style.css"></head><body>{body}</body></html>')
    hp = html_dir / (pathlib.Path(out_pdf).stem + ".html")
    hp.write_text(doc, encoding="utf-8")
    problems = []
    with sync_playwright() as p:
        chrome_candidates = [
            "/usr/bin/google-chrome",
            "/usr/bin/chromium-browser",
            r"C:\Program Files\Google\Chrome\Application\chrome.exe",
            r"C:\Program Files (x86)\Google\Chrome\Application\chrome.exe",
            r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
        ]
        exe = next((c for c in chrome_candidates if os.path.exists(c)), None)
        launch_kwargs = {"args": ["--no-sandbox"]}
        if exe:
            launch_kwargs["executable_path"] = exe
        br = p.chromium.launch(**launch_kwargs)
        pg = br.new_page()
        pg.goto(f"file://{hp}")
        pg.evaluate("document.fonts.ready")
        pg.wait_for_timeout(400)
        over = pg.evaluate("""() => [...document.querySelectorAll('.body')].map((e,i)=>({i:i+1, over:e.scrollHeight-e.clientHeight}))""")
        problems = [o for o in over if o["over"] > 1]
        pg.pdf(path=str(out_pdf), prefer_css_page_size=True, print_background=True)
        br.close()
    return problems


def ulegend(*items):
    """Urdu-first legend. items: (n, urdu_text)"""
    r = "".join(f'<div class="li"><div class="pn">{n}</div><div>{u(t)}</div></div>' for n, t in items)
    return f'<div class="legend">{r}</div>'


def quick(*tiles, title="In 30 seconds · صرف 30 سیکنڈ میں"):
    """tiles: (icon, english, urdu)"""
    t = "".join(f'<div class="q"><div class="qi">{ic(i,6,"#241900",2.6)}</div><b>{e}</b><div class="qu">{uu}</div></div>' for i, e, uu in tiles)
    return f'<div class="quick"><div class="qt">{title}</div>{t}</div>'

def pflow(*nodes):
    """Process flow with big numbered nodes. nodes: (title, small_text, tone) tone in ok/warn/info/''."""
    out = []
    for i, (t, sm, tone) in enumerate(nodes):
        if i: out.append(f'<div class="fa">{ic("arrow",6,"#146C43",2.8)}</div>')
        bg = {"ok": "var(--ok1)", "warn": "var(--warn1)", "info": "var(--info1)"}.get(tone, "#fff")
        bd = {"ok": "#7CCB9B", "warn": "#E2A33B", "info": "#8DB8E8"}.get(tone, "var(--line)")
        out.append(f'<div class="fb" style="background:{bg};border-color:{bd};text-align:center"><div class="num" style="margin:0 auto 1.5mm">{i+1}</div><b>{t}</b><div class="small muted nq">{sm}</div></div>')
    return '<div class="flow">' + "".join(out) + '</div>'
