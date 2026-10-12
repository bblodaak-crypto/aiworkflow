"""Расход лимитов Claude по roadmap: сессии, фазы, итоги и поведение агента.

Читает записи сессий Claude Code (~/.claude/projects/<проект>/*.jsonl) и git.
Сессия относится к roadmap, если её первые сообщения упоминают roadmap NN;
первая сессия, создавшая файл docs/roadmaps/NN-*.md инструментом Write, — его
составление. Коммит принадлежит сессии, где был вызов `git commit` в пределах
двух минут от его времени. Строки работы — добавленные строки в src/, tests/,
data/ по коммитам сессии.

Нагрузка — взвешенные токены по относительной цене API:
чтение кэша ×0,1, запись в кэш ×1,25, ввод ×1, вывод ×5. Это оценка,
формула лимитов подписки не публикуется.

    python3 tools/usage_report.py 10                # отчёт по roadmap 10
    python3 tools/usage_report.py 10 --save         # и снимок в docs/usage/roadmap-10.json
    python3 tools/usage_report.py --history         # итоги всех снимков

Записи сессий Claude Code удаляет через 30 дней (cleanupPeriodDays), поэтому
итоги закрытых roadmap хранятся снимками в docs/usage/.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
# Claude Code называет папку проекта путём, где всё кроме букв и цифр — дефис:
# /Users/me/game → -Users-me-game, C:\Users\me\game → C--Users-me-game.
TRANSCRIPTS = Path.home() / ".claude" / "projects" / re.sub(r"[^A-Za-z0-9]", "-", str(ROOT))
SNAPSHOTS = ROOT / "docs" / "usage"
WORK_PATHS = ("src", "tests", "data")

ROADMAP_RE = re.compile(r"(?:roadmap|рм|р[оа][дт]мап\w*)\W{0,3}0?(\d{1,2})\b|docs/roadmaps/(\d\d)-", re.I)
PHASE_RE = re.compile(r"фаз\w*\W{0,3}(\d+)|phase\W{0,3}(\d+)|steps?\W{0,3}(\d+)\.\d+|шаг\w*\W{0,3}(\d+)\.\d+", re.I)
READ_CMD = re.compile(r"^\s*(cat|sed -n|grep|rg|head|tail|ls|find|wc|nl|git (status|log|diff|show))\b")


def weight(cache_read: int, cache_write: int, inp: int, out: int) -> float:
    return cache_read * 0.1 + cache_write * 1.25 + inp + out * 5


def iso_epoch(stamp: str) -> float:
    return datetime.fromisoformat(stamp.replace("Z", "+00:00")).timestamp()


def first_number(match: re.Match) -> int:
    return int(next(group for group in match.groups() if group))


def tool_kind(name: str, args: dict) -> str:
    if name == "Bash":
        command = args.get("command", "").strip()
        if "sed -i" in command or (command.startswith("python3") and ".write" in command):
            return "edit"
        return "read" if READ_CMD.match(command) else "bash"
    if name in ("Read", "Grep", "Glob"):
        return "read"
    if name in ("Edit", "Write", "MultiEdit", "NotebookEdit"):
        return "edit"
    if name.startswith("mcp__godot__"):
        return "mcp"
    return "other"


def parse_session(path: Path) -> dict | None:
    turns: list[dict] = []
    by_id: dict[str, dict] = {}
    texts: list[str] = []
    stamps: list[float] = []
    entry = ""
    models: set[str] = set()
    launches = screenshots = 0
    commit_calls: list[float] = []
    written: set[str] = set()
    for line in path.open(encoding="utf-8"):
        try:
            record = json.loads(line)
        except json.JSONDecodeError:
            continue
        entry = entry or record.get("entrypoint", "")
        if record.get("timestamp"):
            stamps.append(iso_epoch(record["timestamp"]))
        message = record.get("message") or {}
        if record.get("type") == "user" and not record.get("isMeta") and len(texts) < 3:
            content = message.get("content")
            if isinstance(content, list):
                content = " ".join(part.get("text", "") for part in content if part.get("type") == "text")
            if isinstance(content, str) and content.strip() and not content.startswith("<command"):
                texts.append(content)
        if record.get("type") != "assistant" or "usage" not in message:
            continue
        turn = by_id.get(message.get("id", ""))
        if turn is None:
            usage = message["usage"]
            turn = {
                "cr": usage.get("cache_read_input_tokens", 0),
                "cw": usage.get("cache_creation_input_tokens", 0),
                "in": usage.get("input_tokens", 0),
                "out": usage.get("output_tokens", 0),
                "kinds": [],
            }
            by_id[message.get("id", "")] = turn
            turns.append(turn)
            if not message.get("model", "").startswith("<"):
                models.add(message.get("model", ""))
        for part in message.get("content") or []:
            if isinstance(part, dict) and part.get("type") == "tool_use":
                args = part.get("input", {})
                turn["kinds"].append(tool_kind(part["name"], args))
                if part["name"] == "Bash" and "git commit" in args.get("command", "") and record.get("timestamp"):
                    commit_calls.append(iso_epoch(record["timestamp"]))
                if part["name"] == "Write":
                    written.add(str(args.get("file_path", "")))
                launches += part["name"].endswith("__run_project")
                screenshots += part["name"].endswith("__take_screenshot")
    if not turns or not stamps:
        return None
    subagents = 0.0
    for sub in (path.parent / path.stem / "subagents").glob("*.jsonl"):
        parsed = parse_session(sub)
        subagents += parsed["weight"] if parsed else 0.0
    kinds = []
    for turn in turns:
        found = set(turn["kinds"])
        kinds.append(found.pop() if len(found) == 1 and found <= {"read", "edit", "mcp"} else "mixed")
    repeats = {kind: sum(1 for a, b in zip(kinds, kinds[1:]) if a == b == kind) for kind in ("read", "edit", "mcp")}
    contexts = [turn["cr"] + turn["cw"] + turn["in"] for turn in turns]
    return {
        "id": path.stem[:8],
        "start": min(stamps),
        "end": max(stamps),
        "entry": entry,
        "models": sorted(model.replace("claude-", "") for model in models),
        "prompt": " ".join(texts)[:300].replace("\n", " "),
        "turns": len(turns),
        "calls": sum(len(turn["kinds"]) for turn in turns),
        "base": contexts[0],
        "max_ctx": max(contexts),
        "avg_ctx": sum(contexts) / len(contexts),
        "weight": sum(weight(t["cr"], t["cw"], t["in"], t["out"]) for t in turns) + subagents,
        "subagents": subagents,
        "out": sum(turn["out"] for turn in turns),
        "edit_turns": kinds.count("edit"),
        "repeat_read": repeats["read"],
        "repeat_edit": repeats["edit"],
        "repeat_mcp": repeats["mcp"],
        "launches": launches,
        "screenshots": screenshots,
        "commit_calls": commit_calls,
        "written": sorted(written),
    }


def git(*args: str) -> str:
    return subprocess.run(["git", *args], cwd=ROOT, capture_output=True, text=True, check=True).stdout


def commits() -> list[dict]:
    result = []
    for line in git("log", "--all", "--format=%H%x09%ct%x09%s").splitlines():
        sha, stamp, subject = line.split("\t", 2)
        result.append({"sha": sha, "time": float(stamp), "subject": subject})
    return result


def added_lines(sha: str) -> int:
    total = 0
    for line in git("show", "--numstat", "--format=", sha, "--", *WORK_PATHS).splitlines():
        added = line.split("\t", 1)[0]
        total += int(added) if added.isdigit() else 0
    return total


def owner(commit: dict, sessions: list[dict]) -> dict | None:
    """Сессия с ближайшим вызовом `git commit` не дальше двух минут от коммита."""
    best, gap = None, 120.0
    for session in sessions:
        for call in session["commit_calls"]:
            if abs(commit["time"] - call) <= gap:
                best, gap = session, abs(commit["time"] - call)
    return best


def mentions(text: str, number: int) -> bool:
    return any(first_number(match) == number for match in ROADMAP_RE.finditer(text))


def report(number: int) -> dict:
    sessions = [s for s in (parse_session(p) for p in sorted(TRANSCRIPTS.glob("*.jsonl"))) if s]
    by_session: dict[str, list[dict]] = {}
    for commit in commits():
        session = owner(commit, sessions)
        if session:
            by_session.setdefault(session["id"], []).append(commit)
    marker = f"docs/roadmaps/{number:02d}-"
    creators = [s for s in sessions if any(marker in path for path in s["written"])]
    creator = min(creators, key=lambda s: s["start"])["id"] if creators else None
    rows = []
    for session in sessions:
        inside = by_session.get(session["id"], [])
        own = [c for c in inside if mentions(c["subject"], number)]
        generation = session["id"] == creator
        if not generation and not mentions(session["prompt"], number):
            continue
        if generation:
            kind, phase = "составление", None
        elif own:
            phases = [first_number(m) for c in own for m in PHASE_RE.finditer(c["subject"])]
            prompt_phase = PHASE_RE.search(session["prompt"])
            phase = phases[0] if phases else (first_number(prompt_phase) if prompt_phase else None)
            closing = any(re.search(r"\bclose roadmap\b|roadmap \d+ closed", c["subject"], re.I) for c in own)
            kind = "фаза" if phase is not None else ("закрытие" if closing else "прочее")
        else:
            kind, phase = "прочее", None
        lines = sum(added_lines(c["sha"]) for c in inside)
        session.update(kind=kind, phase=phase, lines=lines, commits=[c["subject"] for c in inside])
        del session["commit_calls"], session["written"]
        rows.append(session)
    rows.sort(key=lambda s: s["start"])
    return {"roadmap": number, "made": datetime.now().isoformat(timespec="minutes"), "sessions": rows}


def totals(rows: list[dict]) -> dict:
    lines = sum(s["lines"] for s in rows)
    turns = sum(s["turns"] for s in rows)
    load = sum(s["weight"] for s in rows)
    return {
        "sessions": len(rows),
        "turns": turns,
        "lines": lines,
        "weight": load,
        "per100": load / lines * 100 if lines else None,
        "turns100": turns / lines * 100 if lines else None,
        "avg_ctx": sum(s["avg_ctx"] * s["turns"] for s in rows) / turns if turns else 0,
        "max_ctx": max((s["max_ctx"] for s in rows), default=0),
        "max_session": max((s["weight"] for s in rows), default=0),
        "calls_per_turn": sum(s["calls"] for s in rows) / turns if turns else 0,
        "repeat_read": sum(s["repeat_read"] for s in rows),
        "repeat_edit": sum(s["repeat_edit"] for s in rows),
        "repeat_mcp": sum(s["repeat_mcp"] for s in rows),
        "edit_turns": sum(s["edit_turns"] for s in rows),
        "launches": sum(s["launches"] for s in rows),
        "screenshots": sum(s["screenshots"] for s in rows),
    }


def k(value: float) -> str:
    return f"{value / 1000:.0f}k"


def m(value: float) -> str:
    return f"{value / 1e6:.2f}M"


def per(value: float | None) -> str:
    return "—" if value is None else k(value)


def print_report(data: dict) -> None:
    rows = data["sessions"]
    print(f"# Roadmap {data['roadmap']:02d}: расход\n")
    if not rows:
        print("Сессий не найдено: записи удалены (старше 30 дней) или roadmap не упоминается в промптах.")
        return
    print("| Сессия | Дата | Вид | Фаза | Модель | Вход | Ходов | Вызовов/ход | База | Ср. контекст | Макс. | Нагрузка | Строк | На 100 строк |")
    print("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
    for s in rows:
        date = datetime.fromtimestamp(s["start"]).strftime("%m-%d %H:%M")
        line_cost = per(s["weight"] / s["lines"] * 100 if s["lines"] else None)
        print(
            f"| {s['id']} | {date} | {s['kind']} | {s['phase'] or ''} | {','.join(s['models'])} | {s['entry']} "
            f"| {s['turns']} | {s['calls'] / s['turns']:.2f} | {k(s['base'])} | {k(s['avg_ctx'])} | {k(s['max_ctx'])} "
            f"| {m(s['weight'])} | {s['lines']} | {line_cost} |"
        )
    print("\n| Группа | Сессий | Ходов | Строк | Нагрузка | На 100 строк | Ходов/100 строк | Ср. контекст | Макс. | Дорогая сессия |")
    print("|---|---|---|---|---|---|---|---|---|---|")
    groups: dict[str, list[dict]] = {}
    for s in rows:
        if s["kind"] == "фаза":
            groups.setdefault(f"фаза {s['phase']}", []).append(s)
    groups["фазы вместе"] = [s for s in rows if s["kind"] == "фаза"]
    groups["весь roadmap (фазы, составление, закрытие)"] = [s for s in rows if s["kind"] != "прочее"]
    for name, group in groups.items():
        t = totals(group)
        turns100 = "—" if t["turns100"] is None else f"{t['turns100']:.1f}"
        print(
            f"| {name} | {t['sessions']} | {t['turns']} | {t['lines']} | {m(t['weight'])} | {per(t['per100'])} "
            f"| {turns100} | {k(t['avg_ctx'])} | {k(t['max_ctx'])} | {m(t['max_session'])} |"
        )
    t = totals(groups["фазы вместе"])
    print("\nПоведение в фазах:")
    print(
        f"- вызовов на ход {t['calls_per_turn']:.2f}; ходов чтения подряд {t['repeat_read']}, правки подряд "
        f"{t['repeat_edit']}, MCP подряд {t['repeat_mcp']} (из {t['turns']}); ходов только с правкой {t['edit_turns']}"
    )
    print(f"- запусков игры {t['launches']}, скриншотов {t['screenshots']}")
    other = [s for s in rows if s["kind"] == "прочее"]
    if other:
        print("\nНе вошли в итоги (упоминают roadmap, но без его коммитов):")
        for s in other:
            print(f"- {s['id']} {m(s['weight'])}: {s['prompt'][:100]}")


def history() -> None:
    print("| Roadmap | Сессий | Строк | Нагрузка фаз | На 100 строк | Ходов/100 | Ср. контекст | Дорогая сессия | Весь roadmap |")
    print("|---|---|---|---|---|---|---|---|---|")
    for path in sorted(SNAPSHOTS.glob("roadmap-*.json")):
        data = json.loads(path.read_text(encoding="utf-8"))
        rows = data["sessions"]
        phases = totals([s for s in rows if s["kind"] == "фаза"])
        whole = totals([s for s in rows if s["kind"] != "прочее"])
        turns100 = "—" if phases["turns100"] is None else f"{phases['turns100']:.1f}"
        print(
            f"| {data['roadmap']:02d} | {phases['sessions']} | {phases['lines']} | {m(phases['weight'])} "
            f"| {per(phases['per100'])} | {turns100} | {k(phases['avg_ctx'])} | {m(phases['max_session'])} "
            f"| {m(whole['weight'])}, {per(whole['per100'])} на 100 |"
        )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("roadmap", nargs="?", type=int)
    parser.add_argument("--save", action="store_true", help="сохранить снимок в docs/usage/")
    parser.add_argument("--history", action="store_true", help="итоги всех снимков")
    args = parser.parse_args()
    if args.history:
        history()
        return 0
    if args.roadmap is None:
        parser.error("нужен номер roadmap или --history")
    data = report(args.roadmap)
    print_report(data)
    if args.save and data["sessions"]:
        SNAPSHOTS.mkdir(exist_ok=True)
        target = SNAPSHOTS / f"roadmap-{args.roadmap:02d}.json"
        target.write_text(json.dumps(data, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
        print(f"\nСнимок: {target.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
