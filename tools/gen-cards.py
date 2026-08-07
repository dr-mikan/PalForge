#!/usr/bin/env python3
"""Generate the PalForge gallery images.   run:  python3 tools/gen-cards.py

One template, three cards. The template is here rather than in three files so the design
language is a definition instead of a convention: change the palette or the anvil once and
every card moves with it.

WHAT WAS HERE BEFORE, and why it is not. This generated nine more — one per domain, framed as
"what you can EXTEND". Two things retired them together: nothing ever referenced them (the docs
site has 61 mermaid diagrams and wanted none of these), and the page was reframed around what a
pack can ADD, which G1-G3 say more briefly. Unreferenced generated output rots, so it went.
`git show 033eafc:tools/gen-cards.py` has all nine definitions if they are ever wanted.

Layout is 1280x720 (the shape a Nexus gallery and a docs hero both take without cropping).

WHY A GENERATOR AND NOT NINE FILES. The cards share a design LANGUAGE, not a resemblance: the
same anvil, the same three colours, the same node/arrow/spark vocabulary, and the same rule that a
DASHED COLD-STEEL BOX means "declared, callable, and with no native source behind it". Nine
hand-written files would drift on all four the first time one of them was edited. Change the
palette here and every card moves with it.

Every code snippet on a card is real, callable API — not pseudocode. If an API changes, the card
that teaches it is wrong, and the fix belongs here.
"""
import io, os, html, textwrap


# ---- the palette, and it is the same three colours as the marks ----------------------
BG      = "#0d1218"
PANEL   = "#141b25"
LINE    = "#243040"
STEEL_L = "#e9eef5"
STEEL_M = "#9fb0c4"
STEEL_D = "#5d6f85"
HEAT_D  = "#c2490f"
HEAT_M  = "#e2621d"
HEAT    = "#f5a524"
HEAT_L  = "#ffd978"

SANS = "Segoe UI, Inter, Helvetica, Arial, sans-serif"
MONO = "Cascadia Mono, Consolas, DejaVu Sans Mono, monospace"

W, H = 1280, 720


def esc(s):
    return html.escape(s, quote=False)


# THE ANVIL, and it had to be redrawn. The first path was a flat slab over an hourglass waist,
# which rasterised into something closer to a bowtie than a tool — the shape was only ever looked
# at as vector source, never as the 1300x372 PNG a visitor actually sees. An anvil is recognised
# by its HORN: the tapering point off one side is the whole silhouette. Everything else — the
# flat face, the undercut, the waist, the wider foot — is what makes the horn read as an anvil
# rather than as a wedge.
ANVIL_PATH = ("M96 302 L152 282 L396 282 L396 320 L336 334 L312 358 L312 384 "
              "L360 384 L360 418 L152 418 L152 384 L200 384 L200 358 L176 334 L116 320 Z")


def anvil(x, y, scale, opacity=1.0):
    """The chosen mark, A, at any size. One definition; every image uses it."""
    return f'''  <g transform="translate({x},{y}) scale({scale})" opacity="{opacity}">
    <path d="{ANVIL_PATH}" fill="url(#steel)"/>
    <rect x="150" y="418" width="212" height="18" rx="6" fill="#43536a"/>
    <circle cx="256" cy="186" r="26" fill="url(#heat)"/>
    <circle cx="196" cy="140" r="13" fill="{HEAT}" opacity="0.9"/>
    <circle cx="318" cy="130" r="10" fill="{HEAT_L}" opacity="0.85"/>
    <circle cx="256" cy="186" r="52" fill="none" stroke="{HEAT}" stroke-width="7" opacity="0.55"/>
  </g>'''


def code_block(x, y, w, lines, title=None):
    """A monospace panel. Lines are (text, kind) where kind tints the row."""
    lh = 27
    top = y
    body_h = len(lines) * lh + 34
    out = [f'  <rect x="{x}" y="{top}" width="{w}" height="{body_h}" rx="12" fill="{PANEL}" stroke="{LINE}" stroke-width="2"/>']
    ty = top + 34
    for text, kind in lines:
        fill = {"code": STEEL_L, "dim": STEEL_D, "hot": HEAT, "key": "#7fb3ff"}.get(kind, STEEL_L)
        out.append(f'  <text x="{x+22}" y="{ty}" font-family="{MONO}" font-size="19" fill="{fill}" xml:space="preserve">{esc(text)}</text>')
        ty += lh
    return "\n".join(out), body_h



# THE FOOTNOTE WRAPS, and it wraps because the raster said so. Every card was written, validated
# as XML and looked at only as vector source; the first 1920x1080 PNG showed the footnote running
# under the brand label on the right and the diagram caption running off the right EDGE. SVG does
# not wrap text — there is no such thing as overflow in a <text> element, it simply keeps going —
# so nothing about the file was wrong and nothing could have caught it except rendering it.
#
# 118 characters is measured from that render, not guessed: at font-size 19 in this sans, the
# 1136 px between the margins holds about that many.
def wrapped(text, x=72, y=None, size=19, fill=None, per_line=118, lh=26):
    y = (H - 74) if y is None else y
    fill = fill or STEEL_D
    lines = textwrap.wrap(text, per_line) or [""]
    if len(lines) > 2:                      # a third line would collide with the diagram
        raise SystemExit(f"footnote too long ({len(text)} chars): {text[:60]}...")
    out = []
    for i, line in enumerate(lines):
        out.append(f'  <text x="{x}" y="{y + i * lh}" font-family="{SANS}" font-size="{size}" '
                   f'fill="{fill}">{esc(line)}</text>')
    return "\n".join(out)


def card(fname, eyebrow, title, blurb, code, diagram, footnote):
    body, ch = code_block(72, 250, 560, code)
    svg = f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}" role="img" aria-label="PalForge — {esc(title)}">
  <title>PalForge — {esc(title)}</title>
  <desc>{esc(blurb)}</desc>
  <defs>
    <linearGradient id="heat" x1="0" y1="1" x2="0" y2="0">
      <stop offset="0" stop-color="#7a2a12"/><stop offset="0.45" stop-color="{HEAT_M}"/>
      <stop offset="0.8" stop-color="{HEAT}"/><stop offset="1" stop-color="{HEAT_L}"/>
    </linearGradient>
    <linearGradient id="steel" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="{STEEL_L}"/><stop offset="0.5" stop-color="{STEEL_M}"/>
      <stop offset="1" stop-color="{STEEL_D}"/>
    </linearGradient>
    <linearGradient id="wire" x1="0" y1="0" x2="1" y2="0">
      <stop offset="0" stop-color="{HEAT_L}"/><stop offset="1" stop-color="{HEAT_M}"/>
    </linearGradient>
    <radialGradient id="glow" cx="0.5" cy="0.5" r="0.5">
      <stop offset="0" stop-color="#ffb545" stop-opacity="0.55"/>
      <stop offset="1" stop-color="#ffb545" stop-opacity="0"/>
    </radialGradient>
  </defs>

  <rect width="{W}" height="{H}" fill="{BG}"/>
  <rect x="0" y="0" width="{W}" height="6" fill="url(#wire)"/>

{anvil(1116, 10, 0.17, 0.9)}
  <text x="{W-72}" y="118" text-anchor="end" font-family="{SANS}" font-size="16" fill="{STEEL_D}">PalForge · single-player</text>

  <text x="72" y="112" font-family="{SANS}" font-size="21" font-weight="600" fill="{HEAT}" letter-spacing="3">{esc(eyebrow)}</text>
  <text x="72" y="176" font-family="{SANS}" font-size="52" font-weight="700" fill="{STEEL_L}">{esc(title)}</text>
  <text x="72" y="216" font-family="{SANS}" font-size="24" fill="{STEEL_M}">{esc(blurb)}</text>

{body}

{diagram}

{wrapped(footnote)}
</svg>
'''
    os.makedirs(OUT, exist_ok=True)
    io.open(os.path.join(OUT, fname), "w", encoding="utf-8").write(svg)
    return fname


# =====================================================================================
# the diagram vocabulary — shared so every card reads the same way
# =====================================================================================

def node(x, y, w, h, label, sub=None, live=True, fill=PANEL):
    stroke = HEAT if live else STEEL_D
    dash = '' if live else ' stroke-dasharray="7 6"'
    out = [f'  <rect x="{x}" y="{y}" width="{w}" height="{h}" rx="12" fill="{fill}" stroke="{stroke}" stroke-width="3"{dash}/>']
    ty = y + (h // 2 + 7) if not sub else y + h // 2 - 4
    out.append(f'  <text x="{x+w//2}" y="{ty}" text-anchor="middle" font-family="{SANS}" font-size="20" font-weight="600" fill="{STEEL_L}">{esc(label)}</text>')
    if sub:
        out.append(f'  <text x="{x+w//2}" y="{y+h//2+24}" text-anchor="middle" font-family="{MONO}" font-size="16" fill="{STEEL_D}">{esc(sub)}</text>')
    return "\n".join(out)


def arrow(x1, y1, x2, y2, label=None, live=True):
    col = HEAT if live else STEEL_D
    dash = '' if live else ' stroke-dasharray="7 6"'
    out = [f'  <path d="M{x1} {y1} L{x2} {y2}" stroke="{col}" stroke-width="4" stroke-linecap="round"{dash}/>']
    # head
    if x2 >= x1:
        out.append(f'  <path d="M{x2-13} {y2-9} L{x2} {y2} L{x2-13} {y2+9} Z" fill="{col}"/>')
    else:
        out.append(f'  <path d="M{x2+13} {y2-9} L{x2} {y2} L{x2+13} {y2+9} Z" fill="{col}"/>')
    if label:
        mx, my = (x1 + x2) // 2, (y1 + y2) // 2 - 12
        out.append(f'  <text x="{mx}" y="{my}" text-anchor="middle" font-family="{MONO}" font-size="16" fill="{col}">{esc(label)}</text>')
    return "\n".join(out)


def spark(cx, cy, r=9):
    return (f'  <circle cx="{cx}" cy="{cy}" r="{r*3}" fill="url(#glow)"/>\n'
            f'  <circle cx="{cx}" cy="{cy}" r="{r}" fill="{HEAT_L}"/>')


# =====================================================================================
# THE NEXUS GALLERY — three cards, and a different question than the nine above
# =====================================================================================
#
# The nine cards answer "what can I extend", domain by domain, which is a documentation
# question. A stranger on a mod page is asking something shorter and blunter: WHAT CAN I ADD.
#
# Five comparable frameworks were read before these were drawn — SMAPI, UE4SS, Fabric, Harmony,
# BepInEx — and NOT ONE of them uses a diagram. Every one leads with a logo, one sentence of the
# form "<category> for <game>", and a download. Harmony, which has exactly this project's problem
# (a library with no visible output), says so explicitly: it does not try to visualise itself.
#
# So three, not nine. Those five can afford zero because they are already known; PalForge is not,
# and "content framework" is not a category anyone recognises. Three is the smallest number that
# answers "what can I add", "what can I add it to", and "how does it fire".
#
# ⚠️ THE ONE CLAIM THAT MUST NOT DRIFT. PalForge alone cannot add a new row to the game's data
# tables — Lua cannot write one. A genuinely new item, creature or build object needs PalSchema
# for the row, and PalForge's namespaced ids are built to be exactly what PalSchema writes
# (`mypack:Potion` -> `mypack_Potion`). Card G1 says that in the picture rather than in a
# footnote, because it is the difference between a framework that works and a page that lies.

OUT = "assets/gallery"
gallery_card = card


# ---- G1: add a new entity -------------------------------------------------------------
d = "\n".join([
    node(700, 250, 234, 96, "PalSchema", "writes the row"),
    arrow(934, 298, 1000, 298),
    node(1000, 250, 208, 96, "the game", "knows it exists"),
    arrow(1104, 346, 1104, 404),
    node(700, 404, 508, 96, "PalForge", "gives it behaviour and events"),
    spark(934, 298, 7),
    f'  <text x="700" y="556" font-family="{SANS}" font-size="19" fill="{STEEL_M}">'
    f'One id, both sides: mypack:Potion → mypack_Potion</text>',
])
gallery_card("G1-new-entity.svg", "ADD SOMETHING NEW", "New pals, items and buildings",
    "PalSchema writes the data row. PalForge gives it behaviour, events and saved state.",
    [('Item{', "code"),
     ('    id       = "mypack:Potion",', "hot"),
     ('    name     = "Healing Potion",', "code"),
     ('    restores = { hpRate = 0.25 },', "code"),
     ('    events   = {', "code"),
     ('        onUse = function(self, ctx)', "code"),
     ('            Audio.get("AKE_Heal"):play()', "code"),
     ('        end,', "code"),
     ('    },', "code"),
     ('}', "code")],
    d,
    "Lua cannot add a row to the game's tables, so a brand-new entity needs PalSchema for the row. PalForge does everything after that.")

# ---- G2: everything you can declare ---------------------------------------------------
cells = [("Pal", "creatures"), ("Item", "things"), ("Building", "structures"),
         ("Skill", "moves & passives"), ("Effect", "status ailments"), ("Audio", "1957 sounds"),
         ("Mesh", "models & materials"), ("UI", "panels")]
g = []
for i, (nm, sub) in enumerate(cells):
    cx = 700 + (i % 2) * 262
    cy = 250 + (i // 2) * 82
    g.append(node(cx, cy, 246, 68, nm, sub))
d = "\n".join(g + [
    f'  <text x="700" y="596" font-family="{SANS}" font-size="19" fill="{STEEL_M}">'
    f'All the same shape: call it, get a handle back.</text>'])
gallery_card("G2-what-you-can-add.svg", "WHAT YOU CAN DECLARE", "Eight kinds of thing, one shape",
    "A pal, an item, a building, a skill, an effect, a sound, a model, a panel.",
    [('Pal{      id = "mypack:Boss",  ... }', "code"),
     ('Item{     id = "mypack:Potion", ... }', "code"),
     ('Building{ id = "mypack:Bench", ... }', "code"),
     ('Skill{    id = "mypack:Ember", ... }', "code"),
     ('Effect{   id = "mypack:Regen", ... }', "code"),
     ('Audio{    id = "AKE_BGM_Title" }', "code"),
     ('Mesh{     id = "mypack:Body",  ... }', "code"),
     ('UI{       id = "mypack:Panel", ... }', "code"), ("", "dim"),
     ('Item.get("Wood"):give(10)   -- and act on it', "dim")],
    d,
    "Every field is checked where you typed it — an undeclared field is an error with a did-you-mean, never a silent no-op.")

# ---- G3: the events ------------------------------------------------------------------
d = "\n".join([
    node(700, 250, 214, 82, "the game", "does a thing"),
    arrow(914, 291, 978, 291),
    node(978, 250, 230, 82, "your handler", "runs"),
    node(700, 356, 508, 74, "onPlace · onRightClick · onTick · onRemove", None),
    node(700, 444, 508, 74, "onUse · onCraft · onObtain · onDiscard", None),
    node(700, 532, 508, 66, "onSpawned · onDamaged · onDeath · onCaptured", None),
    spark(914, 291, 7),
])
gallery_card("G3-events.svg", "AND THE EVENTS ARE ALREADY WIRED", "React to what the game does",
    "Twenty-one channels, fed by twenty-two native hooks. You declare a handler; it fires.",
    [('Building{', "code"),
     ('    id = "CampFire",     -- the vanilla campfire', "dim"),
     ('    events = {', "code"),
     ('        onRightClick = function(self, ctx)', "hot"),
     ('            self.state.uses = self.state.uses + 1', "code"),
     ('            self:save()      -- survives a reload', "code"),
     ('        end,', "code"),
     ('    },', "code"),
     ('}', "code")],
    d,
    "No polling loop to write, no hook to register. A channel with no native source behind it says so instead of staying quiet.")


# ---- G4: where your state lives -------------------------------------------------------
# The one image the "does it touch my save?" section needs. That question is asked on every
# framework page and answering it in prose alone leaves a doubt a picture removes: two boxes
# that never touch, and one of them is the one the player is worried about.
d = "\n".join([
    f'  <text x="700" y="272" font-family="{MONO}" font-size="17" fill="{STEEL_D}">'
    f'ue4ss/Mods/PalForge/state/</text>',
    node(700, 286, 508, 66, "one folder per save", "w_1DF0E44B…"),
    node(724, 368, 226, 66, "yourmod.json", "yours alone"),
    node(982, 368, 226, 66, "othermod.json", "never touched"),
    f'  <rect x="700" y="466" width="508" height="86" rx="12" fill="{PANEL}" '
    f'stroke="{STEEL_D}" stroke-width="3" stroke-dasharray="7 6"/>',
    f'  <text x="954" y="500" text-anchor="middle" font-family="{SANS}" font-size="20" '
    f'font-weight="600" fill="{STEEL_L}">Palworld\u2019s own save</text>',
    f'  <text x="954" y="528" text-anchor="middle" font-family="{MONO}" font-size="16" '
    f'fill="{STEEL_D}">PalForge never writes here</text>',
    f'  <text x="700" y="596" font-family="{SANS}" font-size="19" fill="{STEEL_M}">'
    f'Delete the mod folder and it is all gone.</text>',
])
gallery_card("G4-saved-state.svg", "WHERE YOUR STATE LIVES", "Beside the mod, not inside the save",
    "One folder per save, one file per mod. Plain JSON you can open.",
    [('local db = PalForge.pack("mypack").store', "hot"), ("", "dim"),
     ('db.set("oreBurned", 12)', "code"),
     ('db.get("oreBurned")        --> 12', "dim"),
     ('db.save()', "code"), ("", "dim"),
     ('-- and per placed structure:', "dim"),
     ('function Bench:onRightClick(ctx)', "code"),
     ('    self.state.uses = self.state.uses + 1', "code"),
     ('    self:save()', "code"),
     ('end', "code")],
    d,
    "A crash mid-write leaves the previous version readable, and a file that will not parse is quarantined verbatim rather than overwritten.")

print("  gallery: G1-new-entity, G2-what-you-can-add, G3-events, G4-saved-state")


# =====================================================================================
# THE HEADER — 1300x372, the banner across the top of the mod page
# =====================================================================================
#
# A different shape and therefore a different design, not the banner squashed. At 3.5:1 there is
# room for the mark, the name and one line — and nothing else fits, which is the constraint that
# makes it work: a header that tries to explain gets skimmed past, a header that says WHAT and
# FOR WHAT gets read. The measured build goes on it because it is the one fact a visitor most
# needs before deciding this is for their install.
HW, HH = 1300, 372

header = f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {HW} {HH}" width="{HW}" height="{HH}" role="img" aria-label="PalForge — add new pals, items and buildings to Palworld">
  <title>PalForge</title>
  <desc>A content framework for single-player Palworld, running on UE4SS.</desc>
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#0b1016"/><stop offset="0.5" stop-color="#161d27"/>
      <stop offset="1" stop-color="#0b1016"/>
    </linearGradient>
    <linearGradient id="heat" x1="0" y1="1" x2="0" y2="0">
      <stop offset="0" stop-color="#7a2a12"/><stop offset="0.45" stop-color="{HEAT_M}"/>
      <stop offset="0.8" stop-color="{HEAT}"/><stop offset="1" stop-color="{HEAT_L}"/>
    </linearGradient>
    <linearGradient id="steel" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="{STEEL_L}"/><stop offset="0.5" stop-color="{STEEL_M}"/>
      <stop offset="1" stop-color="{STEEL_D}"/>
    </linearGradient>
    <linearGradient id="wire" x1="0" y1="0" x2="1" y2="0">
      <stop offset="0" stop-color="{HEAT_L}"/><stop offset="1" stop-color="{HEAT_M}"/>
    </linearGradient>
    <radialGradient id="glow" cx="0.5" cy="0.55" r="0.55">
      <stop offset="0" stop-color="#ffb545" stop-opacity="0.42"/>
      <stop offset="1" stop-color="#ffb545" stop-opacity="0"/>
    </radialGradient>
  </defs>

  <rect width="{HW}" height="{HH}" fill="url(#bg)"/>
  <circle cx="196" cy="196" r="228" fill="url(#glow)"/>
  <rect x="0" y="{HH-5}" width="{HW}" height="5" fill="url(#wire)"/>

{anvil(52, 26, 0.62)}

  <text x="410" y="168" font-family="{SANS}" font-size="86" font-weight="700"
        fill="#f2f5f9" letter-spacing="-2">PalForge</text>
  <text x="414" y="222" font-family="{SANS}" font-size="30" fill="{HEAT}">Add new pals, items and buildings to Palworld</text>
  <text x="414" y="270" font-family="{SANS}" font-size="23" fill="{STEEL_M}">Declare it in a few lines of Lua — the game’s own events are already wired</text>
  <text x="414" y="316" font-family="{SANS}" font-size="20" fill="{STEEL_D}">UE4SS · single-player · MIT · measured against Palworld v1.0.2.101103</text>
</svg>
'''
io.open(os.path.join("assets", "header.svg"), "w", encoding="utf-8").write(header)
print("  header: assets/header.svg (1300x372)")


# =====================================================================================
# THE MARK AND THE WIDE BANNER — generated too, so the anvil has ONE definition
# =====================================================================================
#
# These were hand-written before this generator existed, and they kept a COPY of the anvil path.
# When the anvil was redrawn — the first one rasterised into something closer to a bowtie than a
# tool — the two hand-written files silently kept the old shape, and the thumbnail and the GitHub
# social preview would have shipped a different logo from every other image. Two copies of a
# drawing is the same defect as two copies of a sentence.
DEFS = f'''  <defs>
    <linearGradient id="heat" x1="0" y1="1" x2="0" y2="0">
      <stop offset="0" stop-color="#7a2a12"/><stop offset="0.45" stop-color="{HEAT_M}"/>
      <stop offset="0.8" stop-color="{HEAT}"/><stop offset="1" stop-color="{HEAT_L}"/>
    </linearGradient>
    <linearGradient id="steel" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="{STEEL_L}"/><stop offset="0.5" stop-color="{STEEL_M}"/>
      <stop offset="1" stop-color="{STEEL_D}"/>
    </linearGradient>
    <linearGradient id="wire" x1="0" y1="0" x2="1" y2="0">
      <stop offset="0" stop-color="{HEAT_L}"/><stop offset="1" stop-color="{HEAT_M}"/>
    </linearGradient>
    <radialGradient id="glow" cx="0.5" cy="0.6" r="0.55">
      <stop offset="0" stop-color="#ffb545" stop-opacity="0.55"/>
      <stop offset="1" stop-color="#ffb545" stop-opacity="0"/>
    </radialGradient>
  </defs>'''

io.open("assets/logo.svg", "w", encoding="utf-8").write(f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512" width="512" height="512" role="img" aria-label="PalForge">
  <title>PalForge</title>
{DEFS}
  <rect width="512" height="512" rx="96" fill="#12171f"/>
  <circle cx="256" cy="300" r="180" fill="url(#glow)"/>
{anvil(0, 0, 1.0)}
</svg>
''')
print("  mark:   assets/logo.svg (512x512)")

io.open("assets/banner.svg", "w", encoding="utf-8").write(f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1280 640" width="1280" height="640" role="img" aria-label="PalForge — add new pals, items and buildings to Palworld">
  <title>PalForge</title>
{DEFS}
  <rect width="1280" height="640" fill="#0d1218"/>
  <circle cx="290" cy="330" r="290" fill="url(#glow)"/>
  <rect x="0" y="635" width="1280" height="5" fill="url(#wire)"/>
{anvil(60, 92, 0.86)}
  <text x="560" y="268" font-family="{SANS}" font-size="94" font-weight="700" fill="#f2f5f9" letter-spacing="-2">PalForge</text>
  <text x="564" y="326" font-family="{SANS}" font-size="31" fill="{HEAT}">Add new pals, items and buildings to Palworld</text>
  <text x="564" y="380" font-family="{SANS}" font-size="24" fill="{STEEL_M}">Declare it in a few lines of Lua — the game’s own</text>
  <text x="564" y="414" font-family="{SANS}" font-size="24" fill="{STEEL_M}">events are already wired</text>
  <text x="564" y="470" font-family="{SANS}" font-size="20" fill="{STEEL_D}">UE4SS · single-player · MIT · Palworld v1.0.2.101103</text>
</svg>
''')
print("  banner: assets/banner.svg (1280x640)")
