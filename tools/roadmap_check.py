"""Проверка roadmap с шагами (docs/roadmaps/README.md).

Новая сессия читает шапку, вводную фазы и свои шаги, поэтому их размер
ограничен, шаг обязан содержать все поля, а заметка готового шага — дату.

    python3 tools/roadmap_check.py docs/roadmaps
"""

import re
import sys
from pathlib import Path

FIRST_STEPPED = 1
HEADER_MAX = 8000
SECTION_MAX = 3000
STEP_MAX = 4000
STEP_FIELDS = ("**Цель:**", "**Файлы:**", "**Задачи:**", "**Проверка:**", "**Заметка:**")
PHASE = re.compile(r"^## Фаза \d+\. ")
STEP = re.compile(r"^### Шаг \d+\.\d+\. ")
DONE_NOTE = re.compile(r"^\*\*Заметка:\*\* ✅(?! \d{4}-\d{2}-\d{2}\.)", re.MULTILINE)


def blocks(text: str) -> list[tuple[str, str]]:
    """Шапка, затем блоки по заголовкам `##` и `###` вне блоков кода."""
    result = [("шапка", [])]
    in_code = False
    for line in text.split("\n"):
        if line.startswith("```"):
            in_code = not in_code
        if not in_code and re.match(r"^#{2,3} ", line):
            if result[0][0] == "шапка" and len(result) == 1 and not PHASE.match(line):
                result[0][1].append(line)
                continue
            result.append((line, []))
        result[-1][1].append(line)
    return [(title, "\n".join(lines)) for title, lines in result]


def check(path: Path) -> list[str]:
    problems = []
    parts = blocks(path.read_text(encoding="utf-8"))
    header = parts[0][1]
    if not re.search(r"^Текущее: ", header, re.MULTILINE):
        problems.append("в шапке нет строки «Текущее: …»")
    phase_steps: dict[str, int] = {}
    phase = ""
    for title, body in parts:
        size = len(body.encode("utf-8"))
        if title == "шапка":
            limit = HEADER_MAX
        elif STEP.match(title):
            limit = STEP_MAX
            missing = [field for field in STEP_FIELDS if field not in body]
            if missing:
                problems.append(f"{title.lstrip('# ')}: нет {', '.join(missing)}")
            if DONE_NOTE.search(body):
                problems.append(f"{title.lstrip('# ')}: заметка без даты «✅ YYYY-MM-DD.»")
            if phase:
                phase_steps[phase] += 1
        else:
            limit = SECTION_MAX
            phase = title if PHASE.match(title) else ""
            if phase:
                phase_steps[phase] = 0
        if size > limit:
            name = title.lstrip("# ")
            problems.append(f"{name}: {size} байт, лимит {limit}")
    problems += [f"{title.lstrip('# ')}: нет шагов" for title, count in phase_steps.items() if count == 0]
    return [f"{path}: {problem}" for problem in problems]


def main(argv: list[str]) -> int:
    problems = []
    for folder in argv:
        for path in sorted(Path(folder).glob("[0-9][0-9]-*.md")):
            if int(path.name[:2]) >= FIRST_STEPPED:
                problems += check(path)
    for problem in problems:
        print(problem)
    if problems:
        print("Правила формата — docs/roadmaps/README.md.")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
