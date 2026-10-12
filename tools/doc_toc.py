"""Оглавления больших документов.

Оглавление стоит между маркерами `<!-- toc -->` (или `<!-- toc depth=3 -->`) и
`<!-- /toc -->` и собирается из заголовков `##` (и `###` при depth=3).

    python3 tools/doc_toc.py FILE...          обновить оглавления
    python3 tools/doc_toc.py --check FILE...  проверить, что оглавления актуальны
"""

import re
import sys

START = re.compile(r"^<!-- toc(?: depth=(\d))? -->$")
END = "<!-- /toc -->"


def slug(title: str) -> str:
    """Якорь заголовка по правилам GitHub."""
    text = re.sub(r"`|\*\*|\[([^\]]*)\]\([^)]*\)", r"\1", title).strip().lower()
    text = re.sub(r"[^\w\- ]", "", text)
    return text.replace(" ", "-")


def build(text: str) -> str:
    lines = text.split("\n")
    start = next((i for i, line in enumerate(lines) if START.match(line)), None)
    if start is None:
        raise ValueError("нет маркера <!-- toc -->")
    end = lines.index(END, start)
    depth = int(START.match(lines[start]).group(1) or 2)

    entries = []
    seen: dict[str, int] = {}
    in_code = False
    for line in lines[end + 1 :]:
        if line.startswith("```"):
            in_code = not in_code
        if in_code:
            continue
        match = re.match(r"^(#{2,3}) (.+)$", line)
        if not match or len(match.group(1)) > depth:
            continue
        title = match.group(2).strip()
        anchor = slug(title)
        count = seen.get(anchor, 0)
        seen[anchor] = count + 1
        if count:
            anchor = f"{anchor}-{count}"
        indent = "  " * (len(match.group(1)) - 2)
        entries.append(f"{indent}- [{title}](#{anchor})")

    toc = ["**Оглавление**", "", *entries]
    return "\n".join(lines[: start + 1] + toc + lines[end:])


def main(argv: list[str]) -> int:
    check = "--check" in argv
    files = [arg for arg in argv if arg != "--check"]
    stale = []
    for path in files:
        with open(path, encoding="utf-8") as file:
            text = file.read()
        updated = build(text)
        if updated == text:
            continue
        if check:
            stale.append(path)
        else:
            with open(path, "w", encoding="utf-8") as file:
                file.write(updated)
    if stale:
        print("Оглавление устарело: " + ", ".join(stale) + ". Запустите make toc.")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
