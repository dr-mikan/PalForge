#!/usr/bin/env python3
"""Convert the Nexus description from Markdown to BBCode.

    python3 tools/md2bbcode.py publish/nexus-full-description.md

Writes the .bbcode next to it. **The Markdown is the source and the BBCode is build output** —
two hand-kept copies of the same text is how one of them starts lying, and this text carries
claims (version numbers, measurements, what PalForge cannot do) that must not diverge.

WHY A TOOL AND NOT A ONE-OFF. It was a one-off, and the one-off produced a defect that only
showed up when the output was read back: an indented Markdown code block with a BLANK LINE in it
came out as two separate [code] boxes, so the example split in half — `require("palforge.api")`
in one box and the `Building{ ... }` it sets up in another. A reader would have seen two snippets
where there is one. Anything worth checking twice is worth being able to re-run.

WHAT IT DELIBERATELY DOES NOT DO. This is not a general Markdown converter and must not grow
into one. It handles exactly the constructs the description uses, and it FAILS LOUDLY on anything
it does not recognise rather than passing it through as literal text — a stray `**bold**` reaching
a Nexus page is the kind of small wrongness that makes a reader doubt the large claims.
"""
import io
import re
import sys


def convert(md: str) -> str:
    s = md

    # ---- block-level, before anything inline can eat the markers -------------------
    s = re.sub(r'^## (.+)$', r'[size=5][b]\1[/b][/size]', s, flags=re.M)
    s = re.sub(r'^### (.+)$', r'[size=4][b]\1[/b][/size]', s, flags=re.M)
    s = re.sub(r'^---$', '[line]', s, flags=re.M)

    # ---- inline. Links FIRST: a URL can contain characters the others match --------
    s = re.sub(r'\[([^\]]+)\]\((https?://[^)]+)\)', r'[url=\2]\1[/url]', s)
    s = re.sub(r'\*\*(.+?)\*\*', r'[b]\1[/b]', s, flags=re.S)
    s = re.sub(r'(?<![*\w])\*([^*\n]+)\*(?!\*)', r'[i]\1[/i]', s)
    s = re.sub(r'`([^`\n]+)`', r'[font=Courier New]\1[/font]', s)

    # ---- indented code blocks -------------------------------------------------------
    # A blank line does NOT end a block: it is part of the snippet. Only a non-blank,
    # non-indented line does. Getting this wrong is what split the one example in two.
    out, buf, blanks = [], [], []
    for line in s.split('\n'):
        indented = line.startswith('    ') and line.strip()
        if indented:
            buf.extend(blanks); blanks = []
            buf.append(line[4:])
        elif buf and not line.strip():
            blanks.append('')                      # held: it may be inside the block
        else:
            if buf:
                out.append('[code]' + '\n'.join(buf) + '[/code]')
                buf = []
            out.extend(blanks); blanks = []
            out.append(line)
    if buf:
        out.append('[code]' + '\n'.join(buf) + '[/code]')
    out.extend(blanks)
    s = '\n'.join(out)

    # ---- lists. A continuation line is indented and joins the item it follows -------
    out, inlist = [], False
    for line in s.split('\n'):
        bullet = re.match(r'^\* (.*)$', line)
        number = re.match(r'^\d+\. (.*)$', line)
        if bullet:
            if not inlist:
                out.append('[list]'); inlist = True
            out.append('[*]' + bullet.group(1))
        elif number:
            if not inlist:
                out.append('[list=1]'); inlist = True
            out.append('[*]' + number.group(1))
        elif inlist and line.startswith('  ') and line.strip():
            out[-1] += ' ' + line.strip()
        else:
            if inlist:
                out.append('[/list]'); inlist = False
            out.append(line)
    if inlist:
        out.append('[/list]')
    s = '\n'.join(out)

    return re.sub(r'\n{3,}', '\n\n', s).strip() + '\n'


def check(s: str) -> list:
    """Everything worth failing the build over. Returns a list of problems."""
    bad = []
    for tag in ("b", "i", "list", "code", "url", "size", "font"):
        opened = len(re.findall(rf'\[{tag}[\]=]', s))
        closed = len(re.findall(rf'\[/{tag}\]', s))
        if opened != closed:
            bad.append(f"[{tag}] unbalanced: {opened} open, {closed} close")

    # Markdown that survived the conversion would render as literal punctuation.
    leftovers = {
        'heading':  r'^#{1,6} ',
        'bold **':  r'\*\*',
        'link ](':  r'(?<!\[)\]\(',
        'bullet *': r'^\* ',
        'ordered':  r'^\d+\. ',
        'backtick': r'`',
    }
    for name, pat in leftovers.items():
        n = len(re.findall(pat, s, flags=re.M))
        if n:
            bad.append(f"{n} leftover Markdown ({name})")

    # Nexus renders [code] literally, so a tag inside one is shown rather than applied.
    for m in re.finditer(r'\[code\](.*?)\[/code\]', s, flags=re.S):
        found = set(re.findall(r'\[/?(?:b|i|url|font|size)[\]=]', m.group(1)))
        if found:
            bad.append(f"BBCode tags inside a [code] block: {sorted(found)}")

    # An orphan [*] renders as literal text on most BBCode engines.
    depth = 0
    for line in s.split('\n'):
        if re.match(r'^\[list', line):
            depth += 1
        elif line.strip() == '[/list]':
            depth -= 1
        elif line.startswith('[*]') and depth == 0:
            bad.append("a [*] outside any [list]")
            break
    if depth != 0:
        bad.append(f"[list] nesting ends at depth {depth}")
    return bad


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__.strip().split("\n\n")[1])
        return 2
    src = sys.argv[1]
    md = io.open(src, encoding="utf-8").read()

    # The description lives inside a ```markdown fence in its own file, so the file can
    # explain itself above the text that gets pasted. Take the fence if there is one.
    if "```markdown\n" in md:
        md = md.split("```markdown\n", 1)[1].rsplit("\n```", 1)[0]

    out = convert(md)
    dst = src.rsplit(".", 1)[0] + ".bbcode"
    io.open(dst, "w", encoding="utf-8").write(out)

    problems = check(out)
    blocks = out.count("[code]")
    links = out.count("[url=")
    print(f"wrote {dst} — {len(out)} chars, {blocks} code block(s), {links} link(s)")
    for p in problems:
        print("  PROBLEM:", p)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
