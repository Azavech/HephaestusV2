#!/usr/bin/env python3
"""Align markdown tables so every row of a table has its pipes at the same columns.

Usage:
  tables.py --fix FILE...    rewrite files with aligned tables
  tables.py --check FILE...  exit 1 and list tables that are not aligned
Fenced code blocks are left untouched. Cell widths use East Asian width (wide glyphs count as 2).
"""
import sys
import unicodedata


def width(text):
    total = 0
    for ch in text:
        if unicodedata.combining(ch):
            continue
        total += 2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1
    return total


def split_cells(line):
    body = line.strip()
    if body.startswith("|"):
        body = body[1:]
    if body.endswith("|") and not body.endswith("\\|"):
        body = body[:-1]
    cells, current, in_code, i = [], "", False, 0
    while i < len(body):
        ch = body[i]
        if ch == "\\" and i + 1 < len(body) and body[i + 1] == "|":
            current += "\\|"
            i += 2
            continue
        if ch == "`":
            in_code = not in_code
        if ch == "|" and not in_code:
            cells.append(current.strip())
            current = ""
        else:
            current += ch
        i += 1
    cells.append(current.strip())
    return cells


def is_separator(cells):
    return all(c and set(c) <= set(":-") and "-" in c for c in cells)


def format_table(lines):
    rows = [split_cells(l) for l in lines]
    columns = max(len(r) for r in rows)
    rows = [r + [""] * (columns - len(r)) for r in rows]
    sep_index = next((i for i, r in enumerate(rows) if is_separator(r)), None)
    widths = [3] * columns
    for i, r in enumerate(rows):
        if i == sep_index:
            continue
        for c, cell in enumerate(r):
            widths[c] = max(widths[c], width(cell))
    out = []
    for i, r in enumerate(rows):
        if i == sep_index:
            cells = []
            for c, cell in enumerate(r):
                left, right = cell.startswith(":"), cell.endswith(":")
                dashes = "-" * (widths[c] - int(left) - int(right))
                cells.append((":" if left else "") + dashes + (":" if right else ""))
        else:
            cells = [cell + " " * (widths[c] - width(cell)) for c, cell in enumerate(r)]
        out.append("| " + " | ".join(cells) + " |")
    return out


def process(text):
    lines = text.split("\n")
    result, block, fence = [], [], None
    bad = []

    def flush():
        if block:
            formatted = format_table(block)
            if formatted != block:
                bad.append(len(result) + 1)
            result.extend(formatted)
            block.clear()

    for line in lines:
        stripped = line.strip()
        if fence:
            result.append(line)
            if stripped.startswith(fence):
                fence = None
            continue
        if stripped.startswith("```") or stripped.startswith("~~~"):
            flush()
            fence = stripped[:3]
            result.append(line)
            continue
        if stripped.startswith("|"):
            block.append(line)
            continue
        flush()
        result.append(line)
    flush()
    return "\n".join(result), bad


def main(argv):
    if len(argv) < 3 or argv[1] not in ("--fix", "--check"):
        print(__doc__)
        return 2
    failed = False
    for path in argv[2:]:
        with open(path, encoding="utf-8") as handle:
            text = handle.read()
        fixed, bad = process(text)
        if argv[1] == "--fix":
            if fixed != text:
                with open(path, "w", encoding="utf-8") as handle:
                    handle.write(fixed)
        elif bad:
            failed = True
            for line in bad:
                print(f"{path}:{line}: table not aligned")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
