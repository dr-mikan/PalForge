#!/usr/bin/env python3
"""Generate PalForge capability cards as SVG.   run:  python3 tools/gen-cards.py

One template, nine cards. The template is here rather than in nine files so the design
language is a definition instead of a convention: change the palette or the anvil once and
every card moves with it.

Layout is 1280x720 (the shape a Nexus gallery and a docs hero both take without cropping).

WHY A GENERATOR AND NOT NINE FILES. The cards share a design LANGUAGE, not a resemblance: the
same anvil, the same three colours, the same node/arrow/spark vocabulary, and the same rule that a
DASHED COLD-STEEL BOX means "declared, callable, and with no native source behind it". Nine
hand-written files would drift on all four the first time one of them was edited. Change the
palette here and every card moves with it.

Every code snippet on a card is real, callable API — not pseudocode. If an API changes, the card
that teaches it is wrong, and the fix belongs here.
"""
import io, os, html

OUT = "assets/cards"

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


def anvil(x, y, scale, opacity=1.0):
    """The chosen mark, A, at any size. One definition; every card uses it."""
    return f'''  <g transform="translate({x},{y}) scale({scale})" opacity="{opacity}">
    <path d="M126 300 h260 l-26 34 h-49 l-6 26 h48 l22 40 H147 l22-40 h48 l-6-26 h-49 z" fill="url(#steel)"/>
    <rect x="196" y="404" width="120" height="26" rx="8" fill="#43536a"/>
    <circle cx="256" cy="196" r="26" fill="url(#heat)"/>
    <circle cx="196" cy="150" r="13" fill="{HEAT}" opacity="0.9"/>
    <circle cx="318" cy="140" r="10" fill="{HEAT_L}" opacity="0.85"/>
    <circle cx="256" cy="196" r="52" fill="none" stroke="{HEAT}" stroke-width="7" opacity="0.55"/>
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

{anvil(1120, 24, 0.19, 0.9)}

  <text x="72" y="112" font-family="{SANS}" font-size="21" font-weight="600" fill="{HEAT}" letter-spacing="3">{esc(eyebrow)}</text>
  <text x="72" y="176" font-family="{SANS}" font-size="52" font-weight="700" fill="{STEEL_L}">{esc(title)}</text>
  <text x="72" y="216" font-family="{SANS}" font-size="24" fill="{STEEL_M}">{esc(blurb)}</text>

{body}

{diagram}

  <text x="72" y="{H-46}" font-family="{SANS}" font-size="19" fill="{STEEL_D}">{esc(footnote)}</text>
  <text x="{W-72}" y="{H-46}" text-anchor="end" font-family="{SANS}" font-size="18" fill="{STEEL_D}">PalForge · UE4SS Lua · single-player</text>
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
# the nine cards
# =====================================================================================
made = []

# ---- 01 buildings -------------------------------------------------------------------
d = "\n".join([
    node(700, 262, 190, 96, "the campfire", "already in your base"),
    arrow(890, 310, 962, 310, "right-click"),
    node(962, 262, 246, 96, "your handler", "onRightClick"),
    arrow(1085, 358, 1085, 424, "gives"),
    node(962, 424, 246, 88, "Wood x5", "into the inventory"),
    spark(890, 310, 7),
    f'  <text x="700" y="556" font-family="{SANS}" font-size="19" fill="{STEEL_M}">Also live: onPlace · onLoad · onBuild · onTick · onRemove · onWorldReady</text>',
])
made.append(card("01-buildings.svg", "EXTEND A BUILDING", "The game's own structures, given behaviour",
    "No new model, no new build menu entry — the campfire that is already there gains a right-click.",
    [('require("palforge.api")', "dim"), ("", "dim"),
     ('Building{', "code"),
     ('    id = "CampFire",                       ', "code"),
     ('    events = {', "code"),
     ('        onRightClick = function(self, ctx)', "code"),
     ('            Item.get("Wood"):give(5)', "hot"),
     ('        end,', "code"),
     ('    },', "code"),
     ('}', "code")],
    d,
    "Per-structure state survives a reload, and the runtime only enumerates the world when something changed."))

# ---- 02 items -----------------------------------------------------------------------
d = "\n".join([
    node(700, 250, 240, 82, "craft", "item.craft"),
    node(968, 250, 240, 82, "obtain", "item.obtain"),
    node(700, 348, 240, 82, "use", "item.use"),
    node(968, 348, 240, 82, "discard", "item.discard"),
    node(700, 458, 508, 84, "give · take · count", "measured in a real save"),
    spark(940, 291, 6), spark(940, 389, 6),
])
made.append(card("02-items.svg", "EXTEND AN ITEM", "Four channels the game already emits",
    "Craft, obtain, use and discard were each found by hooking the game and watching one fire.",
    [('Item{', "code"),
     ('    id = "Berries",', "code"),
     ('    restores = { satiety = 20 },', "code"),
     ('    events = {', "code"),
     ('        onUse = function(self, ctx)', "code"),
     ('            Effect.get("pack:Regen"):apply(ctx.actor)', "hot"),
     ('        end,', "code"),
     ('    },', "code"),
     ('}', "code"), ("", "dim"),
     ('Item.get("Wood"):give(10)   --> 140 -> 150', "dim")],
    d,
    "give and take were confirmed together in one press: 140 -> 143, then 164 -> 161. Nothing is dropped on the floor."))

# ---- 03 pals ------------------------------------------------------------------------
d = "\n".join([
    node(700, 258, 230, 90, "Pal.get(id)", "any of 753"),
    arrow(930, 303, 1000, 303, ":spawn"),
    node(1000, 258, 208, 90, "in the world", "at your feet"),
    node(700, 380, 508, 82, "mesh · material · skills", "declared, attached on spawn"),
    node(700, 476, 508, 74, "onSpawned · onDamaged · onDeath · onCaptured", None),
    spark(930, 303, 7),
])
made.append(card("03-pals.svg", "EXTEND A PAL", "Spawn one, dress it, teach it",
    "A declared mesh attaches itself the moment the pawn finishes initialising.",
    [('Pal{', "code"),
     ('    id   = "pack:Boss",', "code"),
     ('    mesh = { model = Mesh.assets.SK.PinkCat },', "hot"),
     ('    skills = { "FireBlast" },', "code"),
     ('    events = {', "code"),
     ('        onSpawned = function(pal, ctx) end,', "code"),
     ('    },', "code"),
     ('}', "code"), ("", "dim"),
     ('Pal.get("ChickenPal"):spawn(Player.coordinate())', "dim")],
    d,
    "A spawn arrives 4-6 seconds later, so :spawn answers whether the call was ISSUED — and the log says when it landed."))

# ---- 04 skills & effects ------------------------------------------------------------
d = "\n".join([
    node(700, 250, 240, 86, "skill.activate", "PalActionBase"),
    node(968, 250, 240, 86, "skill.equip", "AddPassiveSkill"),
    node(700, 352, 508, 86, "38 native ailments", "status.add / status.remove"),
    node(700, 454, 508, 78, "skill.hit", "no native source on this build", live=False),
    spark(940, 293, 6),
])
made.append(card("04-skills-effects.svg", "EXTEND A SKILL OR AN EFFECT", "Moves, passives, and the game's own ailments",
    "309 active moves are an enum; passives are names. Effects can ride a real Palworld status.",
    [('Effect{', "code"),
     ('    id = "pack:Regen", duration = 10.0,', "code"),
     ('    nativeStatus = "AttackUp",', "hot"),
     ('    interval = 1.0,', "code"),
     ('    events = {', "code"),
     ('        onTick = function(e, target, ctx) end,', "code"),
     ('    },', "code"),
     ('}', "code"), ("", "dim"),
     ('Skill.get("FireBlast"):teach(pal)', "dim")],
    d,
    "The dashed box is the shared vocabulary of these images: declared, callable, and with no native source behind it."))

# ---- 05 ui --------------------------------------------------------------------------
d = "\n".join([
    f'  <rect x="700" y="250" width="508" height="252" rx="14" fill="{PANEL}" stroke="{LINE}" stroke-width="3"/>',
    f'  <text x="722" y="284" font-family="{SANS}" font-size="17" fill="{STEEL_D}">Palworld’s own layout</text>',
    node(736, 302, 300, 92, "your panel", "mounted, not drawn over"),
    f'  <rect x="1060" y="302" width="128" height="92" rx="10" fill="none" stroke="{LINE}" stroke-width="3"/>',
    f'  <text x="1124" y="354" text-anchor="middle" font-family="{SANS}" font-size="17" fill="{STEEL_D}">the HUD</text>',
    node(736, 414, 452, 68, "keys · mouse buttons · back handler", None),
    f'  <text x="700" y="556" font-family="{SANS}" font-size="19" fill="{STEEL_M}">A press is ROUTED, never consumed — the game still gets it.</text>',
])
made.append(card("05-ui.svg", "EXTEND THE INTERFACE", "A panel inside the game's own UI",
    "Declared as a tree, mounted into Palworld's layout, and it takes itself down.",
    [('UI{', "code"),
     ('    id   = "pack:Panel",', "code"),
     ('    host = "game",', "code"),
     ('    keys = { "INS" },', "hot"),
     ('    root = UI.Frame{', "code"),
     ('        UI.VBox{', "code"),
     ('            UI.Label{ text = "Ore burned: 12" },', "code"),
     ('            UI.Button{ text = "Reset" },', "code"),
     ('        },', "code"),
     ('    },', "code"),
     ('}', "code")],
    d,
    "PalForge never calls SetInputMode itself. The game's own action router owns the input mode; doing otherwise broke Esc twice."))

# ---- 06 audio & mesh ----------------------------------------------------------------
d = "\n".join([
    node(700, 252, 508, 86, "1957 sounds, from the game", "Audio.get(id):play()"),
    node(700, 352, 246, 86, "vanilla meshes", "/Game/... paths"),
    node(962, 352, 246, 86, "your .obj", "off disk"),
    node(700, 454, 246, 78, "custom texture", "wired, unproven", live=False),
    node(962, 454, 246, 78, "custom sound", "refused, and says so", live=False),
    spark(1208, 295, 6),
])
made.append(card("06-audio-mesh.svg", "EXTEND THE LOOK AND THE SOUND", "Vanilla assets, and the honest limits",
    "A pack can reference anything the game ships. What it cannot ship itself is stated, not hidden.",
    [('Audio.get("AKE_General_Explosion"):play()', "code"), ("", "dim"),
     ('Mesh{', "code"),
     ('    id    = "pack:Marker",', "code"),
     ('    kind  = "procedural",', "code"),
     ('    model = "art/marker.obj",     -- pack-relative', "hot"),
     ('    color = { 0.9, 0.3, 0.1, 1 },', "code"),
     ('}', "code"), ("", "dim"),
     ('Mesh.assets.SM.ChestWood   -- a path known to exist', "dim")],
    d,
    "Material parameter names were read off the running game, because a header dump could never have said them."))

# ---- 07 state -----------------------------------------------------------------------
d = "\n".join([
    f'  <text x="700" y="272" font-family="{MONO}" font-size="17" fill="{STEEL_D}">ue4ss/Mods/PalForge/state/</text>',
    node(700, 290, 508, 74, "w_1DF0E44B…  (one folder per save)", None),
    node(724, 384, 226, 74, "yourmod.json", "yours alone"),
    node(982, 384, 226, 74, "othermod.json", "never touched"),
    node(700, 478, 508, 70, "delete the mod folder and it is all gone", None),
    f'  <text x="700" y="586" font-family="{SANS}" font-size="19" fill="{STEEL_M}">PalForge never writes to Palworld’s own save.</text>',
])
made.append(card("07-state.svg", "KEEP STATE", "Per-mod, per-save, and outside the game's save file",
    "Your mod gets a slice with its id baked in. There is no way to reach another mod's store.",
    [('local db = PalForge.pack("mypack").store', "hot"), ("", "dim"),
     ('db.set("oreBurned", 12)', "code"),
     ('db.get("oreBurned")            --> 12', "dim"),
     ('db.save()', "code"), ("", "dim"),
     ('-- and per placed structure:', "dim"),
     ('function Bench:onRightClick(ctx)', "code"),
     ('    self.state.uses = self.state.uses + 1', "code"),
     ('    self:save()', "code"),
     ('end', "code")],
    d,
    "A crash mid-write leaves the previous version readable; an unreadable file is quarantined verbatim, never overwritten."))

# ---- 08 events ----------------------------------------------------------------------
d = "\n".join([
    node(700, 252, 220, 84, "the game", "RegisterHook"),
    arrow(920, 294, 992, 294),
    node(992, 252, 216, 84, "21 channels", "one bus"),
    arrow(1100, 336, 1100, 396),
    node(700, 396, 508, 84, "your handlers", "dispatched by id"),
    node(700, 494, 508, 74, "22 native sources · 2 timers", None),
    spark(920, 294, 7),
])
made.append(card("08-events.svg", "THE EVENT MODEL", "Push, not poll",
    "Twenty-two native hooks feed twenty-one channels. Only two things in the tree are on a timer.",
    [('event.on("building.place", function(ctx)', "code"),
     ('    log.info(ctx.buildId)', "code"),
     ('end)', "code"), ("", "dim"),
     ('-- a channel that has never fired says so:', "dim"),
     ('--   building.break  no native source', "dim"),
     ('--   skill.hit       measured silent, twice', "dim"), ("", "dim"),
     ('-- measured in a 623-structure base:', "dim"),
     ('--   2.2 ms a sweep, 4 of 120 doing work', "hot")],
    d,
    "The building runtime enumerates the world only when something happened that could have changed it."))

# ---- 09 packs -----------------------------------------------------------------------
d = "\n".join([
    node(700, 250, 240, 88, "mypack", "owns its ids"),
    node(968, 250, 240, 88, "otherpack", "owns its own"),
    arrow(940, 294, 968, 294, None, live=False),
    node(700, 356, 508, 82, "a collision is named, not silent", "last wins, and says so"),
    node(700, 458, 508, 82, "PalForge.pack(id).store", "isolation is the surface"),
    spark(700, 294, 6),
])
made.append(card("09-packs.svg", "SHIP A PACK", "Two mods, one game, no collisions",
    "Ids are namespaced per domain, and every definition records who made it.",
    [('local api = PalForge.pack("mypack", {', "hot"),
     ('    version = "1.0.0",', "code"),
     ('    depends = { "otherpack" },', "code"),
     ('})', "hot"), ("", "dim"),
     ('api.Item{ id = "mypack:Potion" }', "code"),
     ('--   the game data row is  mypack_Potion', "dim"), ("", "dim"),
     ('-- referencing another pack without declaring', "dim"),
     ('-- a dependency warns, by name.', "dim")],
    d,
    "Registering an id another pack holds is last-wins — but it is logged with both owners, which is the part that was missing."))

for f in made:
    print("  wrote", f)


# =====================================================================================
# the contact sheet — one file that shows the whole set
# =====================================================================================
#
# Built from the nine files just written rather than from the definitions above, so it can only
# ever show what actually shipped. The cards' <defs> are identical in all nine, so one copy is
# kept and the rest dropped; ids do not collide because there is only one of each.
import re

SHEET = [("01","buildings","Extend a building"), ("02","items","Extend an item"),
         ("03","pals","Extend a pal"),           ("04","skills-effects","Skills &amp; effects"),
         ("05","ui","Extend the interface"),     ("06","audio-mesh","Look &amp; sound"),
         ("07","state","Keep state"),            ("08","events","The event model"),
         ("09","packs","Ship a pack")]

CW, CH, GAP, PAD, LAB, COLS, ROWS = 386, 217, 26, 56, 40, 3, 3
SW = PAD * 2 + COLS * CW + (COLS - 1) * GAP
SH = PAD * 2 + 78 + ROWS * (CH + LAB) + (ROWS - 1) * GAP

parts, sheet_defs = [], []
for i, (num, slug, title) in enumerate(SHEET):
    src = io.open(os.path.join(OUT, f"{num}-{slug}.svg"), encoding="utf-8").read()
    inner = src[src.index(">", src.index("<svg")) + 1: src.rindex("</svg>")]
    inner = re.sub(r"<(title|desc)>.*?</\1>", "", inner, flags=re.S)
    d = re.search(r"<defs>.*?</defs>", inner, flags=re.S)
    if d:
        if not sheet_defs:
            sheet_defs.append(d.group(0)[6:-7])
        inner = inner.replace(d.group(0), "")
    c, r = i % COLS, i // COLS
    x = PAD + c * (CW + GAP)
    y = PAD + 78 + r * (CH + LAB + GAP)
    parts.append(
        f'  <g transform="translate({x},{y}) scale({CW/1280:.5f})" clip-path="url(#clip)">{inner}</g>\n'
        f'  <rect x="{x}" y="{y}" width="{CW}" height="{CH}" fill="none" stroke="{LINE}" stroke-width="2" rx="6"/>\n'
        f'  <text x="{x}" y="{y+CH+26}" font-family="{SANS}" font-size="17" font-weight="600" '
        f'fill="{STEEL_L}">{num} \u00b7 {title}</text>\n')

io.open(os.path.join(OUT, "_sheet.svg"), "w", encoding="utf-8").write(
    f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {SW} {SH}" width="{SW}" height="{SH}" '
    f'role="img" aria-label="PalForge capability cards">\n  <title>PalForge capability cards</title>\n'
    f'  <defs><clipPath id="clip"><rect x="0" y="0" width="{W}" height="{H}"/></clipPath>'
    f'{"".join(sheet_defs)}</defs>\n'
    f'  <rect width="{SW}" height="{SH}" fill="{BG}"/>\n'
    f'  <rect x="0" y="0" width="{SW}" height="5" fill="{HEAT}"/>\n'
    f'  <text x="{PAD}" y="{PAD+22}" font-family="{SANS}" font-size="30" font-weight="700" '
    f'fill="#f2f5f9">PalForge \u2014 what a pack can extend</text>\n'
    f'  <text x="{PAD}" y="{PAD+54}" font-family="{SANS}" font-size="18" fill="{HEAT}">'
    f'nine cards, one design language \u00b7 dashed cold steel = declared, with no native source</text>\n'
    + "".join(parts) + '</svg>\n')
print("  wrote _sheet.svg")


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

GALLERY = "assets/gallery"


def gallery_card(fname, eyebrow, title, blurb, code, diagram, footnote):
    global OUT
    keep, OUT = OUT, GALLERY
    try:
        return card(fname, eyebrow, title, blurb, code, diagram, footnote)
    finally:
        OUT = keep


# ---- G1: add a new entity -------------------------------------------------------------
d = "\n".join([
    node(700, 250, 234, 96, "PalSchema", "writes the row"),
    arrow(934, 298, 1000, 298),
    node(1000, 250, 208, 96, "the game", "knows it exists"),
    arrow(1104, 346, 1104, 404),
    node(700, 404, 508, 96, "PalForge", "gives it behaviour and events"),
    spark(934, 298, 7),
    f'  <text x="700" y="556" font-family="{SANS}" font-size="19" fill="{STEEL_M}">'
    f'One id, spelled the same on both sides: mypack:Potion → mypack_Potion</text>',
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
    f'Every one is the same shape: call it to define, get a handle back.</text>'])
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

print("  gallery: G1-new-entity.svg, G2-what-you-can-add.svg, G3-events.svg")
