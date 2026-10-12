"""Генерация картинок ChatGPT через Codex CLI (ADR-0001).

Одна задача — одна картинка: промпт с эталоном `design/reference/style.png`
уходит в `codex exec` (встроенный `image_gen`, по подписке, без ключа API), PNG
кладётся в папку набора, промпт и ответ дописываются в её `PROMPTS.md`. Фон —
ровный белый: его снимает `tools/image_matte.gd`; `--scene` — цельная картинка
(концепт локации, плитка земли) без строки о фоне. Логи — `build/art-logs/`.

    python3 tools/art/gen.py check
    python3 tools/art/gen.py one NAME PROMPT --out DIR [--ref IMG[=подпись]]… [--size WxH] [--scene]
                                 [--provider codex|manual] [--no-wait] [--dry-run]
    python3 tools/art/gen.py batch JOBS.json [--jobs N] [--provider P] [--no-wait] [--dry-run]

PROMPT — текст или путь к файлу с ним. JOBS.json — список задач
`{"name", "prompt", "out", "ref": [...], "size": "WxH", "scene", "provider"}` или `{"jobs": [...]}`.
Провайдер `manual` пишет заявку в `build/art/requests/` и ждёт файл `DIR/NAME.png` от пользователя.

Вызов Codex и поиск картинки перенесены из скилла ref2game (scripts/gen.py,
`codex_generate`, `manual_generate`): Copyright (c) 2026 studioigor, MIT License.
"""

from __future__ import annotations

import argparse
import datetime
import json
import math
import os
import re
import shlex
import shutil
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
STYLE_REF = ROOT / "design/reference/style.png"
LOG_DIR = ROOT / "build/art-logs"
WORK_DIR = ROOT / "build/art"
DEFAULT_SIZE = (1536, 1024)
PROVIDERS = ("codex", "manual")
CODEX_TIMEOUT = 900.0
MANUAL_TIMEOUT = 86400.0

CODEX_PREAMBLE = (
    "Use your built-in image_gen tool (not a CLI, script or API call) to generate ONE image, "
    "then copy the generated PNG file into this workspace as {path} (create folders if needed). "
    "Do not write any code or edit other files."
)
STYLE_LABEL = (
    "style reference only: match its art style, rendering, palette and light; "
    "do not copy its composition"
)
EXTRA_LABEL = "reference for this asset: use it as the ASSET text describes"
BACKGROUND_LINE = (
    "Background: perfectly flat solid white #FFFFFF everywhere outside the objects; "
    "no texture, no gradient, no vignette, no frame, no ground plane, no cast shadow, no text"
)
IMAGE_SUFFIXES = (".png", ".webp", ".jpg", ".jpeg")
PNG_MAGIC = b"\x89PNG\r\n\x1a\n"


class GenError(Exception):
    """Ошибка, которую стоит показать пользователю без трассировки."""


@dataclass
class Job:
    name: str
    prompt: str
    out_dir: Path
    refs: list[tuple[Path, str]] = field(default_factory=list)
    size: tuple[int, int] = DEFAULT_SIZE
    provider: str = "codex"
    scene: bool = False

    @property
    def out(self) -> Path:
        return self.out_dir / f"{self.name}.png"


def parse_size(text: str | None) -> tuple[int, int]:
    if not text:
        return DEFAULT_SIZE
    match = re.fullmatch(r"(\d+)[xX×](\d+)", text.strip())
    if not match:
        raise GenError(f"размер «{text}»: нужен вид WxH, например 1536x1024")
    return int(match[1]), int(match[2])


def parse_ref(text: str) -> tuple[Path, str]:
    """`IMG` или `IMG=подпись`; путь относительно корня проекта."""
    path, _, label = text.partition("=")
    return _abs(path), label.strip() or EXTRA_LABEL


def read_prompt(text: str) -> str:
    """Промпт — путь к существующему файлу или сам текст."""
    candidate = _abs(text) if len(text) < 300 and "\n" not in text else None
    if candidate is not None and candidate.is_file():
        text = candidate.read_text(encoding="utf-8")
    if not text.strip():
        raise GenError("пустой промпт")
    return text.strip()


def make_job(spec: dict, base: dict | None = None) -> Job:
    """Задача из `one` или строки `batch`; флаги командной строки `base` важнее полей задачи."""
    merged = {**spec, **{k: v for k, v in (base or {}).items() if v is not None}}
    for key in ("name", "prompt", "out"):
        if not merged.get(key):
            raise GenError(f"в задаче нет поля «{key}»")
    name = str(merged["name"])
    if not re.fullmatch(r"[a-z0-9][a-z0-9_.-]*", name):
        raise GenError(f"имя «{name}»: только строчные латинские буквы, цифры, _ . -")
    provider = merged.get("provider") or "codex"
    if provider not in PROVIDERS:
        raise GenError(f"провайдер «{provider}»: есть только {', '.join(PROVIDERS)}")
    refs = ref_list([parse_ref(r) for r in merged.get("ref") or []])
    prompt = read_prompt(str(merged["prompt"]))
    size = parse_size(merged.get("size"))
    return Job(name, prompt, _abs(str(merged["out"])), refs, size, provider, bool(merged.get("scene")))


def ref_list(extra: list[tuple[Path, str]], style_ref: Path | None = None) -> list[tuple[Path, str]]:
    """Эталон стиля всегда первый (ADR-0001); без него и с пропавшим файлом — отказ."""
    style_ref = style_ref or STYLE_REF
    if not style_ref.is_file():
        raise GenError(f"нет эталона стиля {_rel(style_ref)}: без него генерация запрещена")
    refs = [(style_ref, STYLE_LABEL)] + [r for r in extra if r[0].resolve() != style_ref.resolve()]
    missing = [_rel(path) for path, _ in refs if not path.is_file()]
    if missing:
        raise GenError(f"нет файлов эталонов: {', '.join(missing)}")
    return refs


def build_prompt(asset: str, refs: list[tuple[Path, str]], size: tuple[int, int], scene: bool = False) -> str:
    parts = []
    if refs:
        lines = ["REFERENCE IMAGES (attached in this order):"]
        lines += [f"Image {i} ({path.name}) = {label}" for i, (path, label) in enumerate(refs, 1)]
        parts.append("\n".join(lines))
    parts.append("ASSET:\n" + asset.strip())
    w, h = size
    g = math.gcd(w, h)
    orient = "landscape" if w > h else "portrait" if h > w else "square"
    parts.append(
        f"Canvas: {w}x{h} px ({w // g}:{h // g} {orient}); if that exact size is unavailable, "
        "use the closest size with the same aspect ratio."
    )
    if not scene:
        parts.append(BACKGROUND_LINE)
    return "\n\n".join(parts)


def codex_command(exe: str, refs: list[tuple[Path, str]]) -> list[str]:
    cmd = [exe, "exec", "--skip-git-repo-check", "-s", "workspace-write", "-C", str(ROOT)]
    cmd += ["-c", 'model_reasoning_effort="low"']
    for path, _ in refs:
        cmd += ["-i", str(path)]
    return cmd + ["--", "-"]


def find_image(log_text: str, target: Path, since: float, codex_home: Path) -> Path | None:
    """Картинка задачи: скопированная Codex, путь из лога или папка сессии в generated_images."""
    if target.is_file() and target.stat().st_mtime >= since - 1:
        return target
    # Путь в логе: /Users/…/generated_images/… или C:\Users\…\generated_images\…
    pattern = r"((?:[A-Za-z]:)?[\\/][^\s'\"`]*generated_images[\\/][^\s'\"`]+?\.(?:png|webp|jpe?g))"
    found = [Path(p) for p in re.findall(pattern, log_text)]
    found = [p for p in found if p.is_file() and p.stat().st_mtime >= since - 1]
    if not found:
        session = re.search(r"session id:\s*([0-9a-f-]{8,})", log_text)
        if session:
            folder = codex_home / "generated_images" / session[1]
            found = [p for p in folder.glob("*") if p.suffix.lower() in IMAGE_SUFFIXES]
    return max(found, key=lambda p: p.stat().st_mtime) if found else None


def codex_generate(job: Job, prompt: str, dry_run: bool) -> dict:
    target = WORK_DIR / "codex" / f"{job.name}.png"
    log = LOG_DIR / f"{job.name}.log"
    full = CODEX_PREAMBLE.format(path=_rel(target)) + "\n\n" + prompt
    exe = shutil.which("codex")
    cmd = codex_command(exe or "codex", job.refs)
    if dry_run:
        say(job.name, f"[dry-run] {shlex.join(cmd)} < промпт > {_rel(log)}")
        say(job.name, f"[dry-run] ждать {_rel(target)} или generated_images, затем → {_rel(job.out)}")
        return {"status": "dry-run"}
    if not exe:
        raise GenError("codex не найден в PATH: npm i -g @openai/codex, затем codex login")
    build_dir(log.parent)
    build_dir(target.parent)
    started = time.time()
    with log.open("wb") as out:
        try:
            done = subprocess.run(
                cmd, input=full.encode("utf-8"), stdout=out, stderr=subprocess.STDOUT, timeout=CODEX_TIMEOUT
            )
        except subprocess.TimeoutExpired as error:
            raise GenError(f"codex не ответил за {CODEX_TIMEOUT:.0f} с, лог {_rel(log)}") from error
    text = log.read_text(encoding="utf-8", errors="replace")
    codex_home = Path(os.environ.get("CODEX_HOME", Path.home() / ".codex"))
    source = find_image(text, target, started, codex_home)
    if source is None:
        tail = "\n".join(text.strip().splitlines()[-12:])
        raise GenError(f"codex завершился (код {done.returncode}) без картинки, лог {_rel(log)}\n{tail}")
    if source != target:
        say(job.name, f"codex не скопировал файл, беру {source}")
    saved = save_image(source.read_bytes(), job.out)
    if source == target:
        target.unlink()
    session = re.search(r"session id:\s*([0-9a-f-]{8,})", text)
    seconds = round(time.time() - started)
    return {"status": "ok", "path": saved, "session": session[1] if session else None, "seconds": seconds}


def manual_generate(job: Job, prompt: str, dry_run: bool, wait: bool = True) -> dict:
    request = WORK_DIR / "requests" / f"{job.name}.txt"
    lines = [
        f"# Заявка на картинку {job.name}",
        "# 1. Сгенерируйте ОДНУ картинку по промпту ниже, приложив эталоны в этом порядке:",
        *[f"#    {i}. {path}" for i, (path, _) in enumerate(job.refs, 1)],
        f"# 2. Размер {job.size[0]}x{job.size[1]} (или ближайший с теми же пропорциями).",
        f"# 3. Сохраните PNG как {job.out}",
        "",
        prompt,
        "",
    ]
    if dry_run:
        say(job.name, f"[dry-run] заявка {_rel(request)}, ждать {_rel(job.out)}")
        return {"status": "dry-run"}
    build_dir(request.parent)
    request.write_text("\n".join(lines), encoding="utf-8")
    asked = request.stat().st_mtime
    say(job.name, f"РУЧНОЙ РЕЖИМ: заявка {_rel(request)}, положите картинку в {_rel(job.out)}")
    if not wait:
        return {"status": "pending"}
    deadline = time.time() + MANUAL_TIMEOUT
    while not (job.out.is_file() and job.out.stat().st_mtime > asked):
        if time.time() > deadline:
            raise GenError(f"файл {_rel(job.out)} так и не появился")
        time.sleep(3)
    time.sleep(1)
    request.replace(request.with_suffix(".done.txt"))
    return {"status": "ok", "path": job.out, "session": None, "seconds": round(time.time() - asked)}


def save_image(data: bytes, out: Path) -> Path:
    """Пишет картинку в `out`; прежний файл уходит в `build/art/old/`, не в мусор."""
    if not data.startswith(PNG_MAGIC):
        raise GenError(f"{_rel(out)}: генератор вернул не PNG — переведите в PNG вручную")
    out.parent.mkdir(parents=True, exist_ok=True)
    if out.exists():
        stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
        backup = WORK_DIR / "old" / f"{out.stem}-{stamp}{out.suffix}"
        build_dir(backup.parent)
        shutil.copy2(out, backup)
        say(out.stem, f"прежний файл сохранён в {_rel(backup)}")
    out.write_bytes(data)
    return out


def record_prompt(job: Job, prompt: str, result: dict) -> None:
    """Дописывает промпт и ответ в `PROMPTS.md` папки набора (ADR-0001, «Где что лежит»)."""
    log = job.out_dir / "PROMPTS.md"
    head = "" if log.exists() else f"# {job.out_dir.name} — промпты\n\nПишет `tools/art/gen.py`.\n"
    when = datetime.datetime.now().strftime("%Y-%m-%d %H:%M")
    refs = "\n".join(f"{i}. `{_rel(path)}`" for i, (path, _) in enumerate(job.refs, 1))
    answer = f"`{_rel(result['path'])}`"
    if result.get("session"):
        answer += f", сессия Codex `{result['session']}`"
    body = (
        f"\n## {job.name} — {when}\n\n"
        f"Провайдер `{job.provider}`, холст {job.size[0]}x{job.size[1]}, ответ {answer}"
        f"{', ' + str(result['seconds']) + ' с' if result.get('seconds') is not None else ''}.\n\n"
        f"Эталоны по порядку:\n\n{refs}\n\n```text\n{prompt}\n```\n"
    )
    with log.open("a", encoding="utf-8") as file:
        file.write(head + body)


def run_job(job: Job, dry_run: bool, wait: bool = True) -> dict:
    prompt = build_prompt(job.prompt, job.refs, job.size, job.scene)
    try:
        if job.provider == "codex":
            result = codex_generate(job, prompt, dry_run)
        else:
            result = manual_generate(job, prompt, dry_run, wait)
    except GenError as error:
        say(job.name, f"ОШИБКА: {error}")
        return {"name": job.name, "status": "error"}
    if result["status"] == "ok":
        record_prompt(job, prompt, result)
        say(job.name, f"готово: {_rel(result['path'])} ({result.get('seconds', '?')} с)")
    return {"name": job.name, **result}


def load_jobs(path: Path, base: dict) -> list[Job]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise GenError(f"{_rel(path)}: {error}") from error
    specs = data.get("jobs", []) if isinstance(data, dict) else data
    if not isinstance(specs, list) or not specs:
        raise GenError(f"{_rel(path)}: нужен непустой список задач")
    jobs = [make_job(spec, base) for spec in specs]
    names = [job.name for job in jobs]
    repeated = sorted({n for n in names if names.count(n) > 1})
    if repeated:
        raise GenError(f"{_rel(path)}: повторяются имена {', '.join(repeated)}")
    return jobs


def codex_status() -> tuple[bool, str]:
    exe = shutil.which("codex")
    if not exe:
        return False, "codex не найден в PATH"
    try:
        out = subprocess.run([exe, "login", "status"], capture_output=True, text=True, timeout=20)
    except (OSError, subprocess.TimeoutExpired) as error:
        return False, f"codex login status: {error}"
    lines = (out.stdout + out.stderr).strip().splitlines()
    last = lines[-1] if lines else ""
    ok = out.returncode == 0 and "logged in" in last.lower() and "not" not in last.lower()
    return ok, last or "нет ответа, выполните codex login"


def cmd_check() -> int:
    ok, detail = codex_status()
    say("codex", f"{'готов' if ok else 'НЕ ГОТОВ'}: {detail}")
    has_ref = STYLE_REF.is_file()
    say("эталон", f"{_rel(STYLE_REF)} {'есть' if has_ref else 'НЕТ'}")
    say("manual", "готов: заявки в build/art/requests/")
    return 0 if ok and has_ref else 1


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="gen.py", description="Картинки ChatGPT через Codex CLI.")
    sub = parser.add_subparsers(dest="cmd", required=True)
    sub.add_parser("check", help="готов ли Codex и есть ли эталон")
    one = sub.add_parser("one", help="одна картинка")
    one.add_argument("name")
    one.add_argument("prompt", help="текст промпта или путь к файлу")
    one.add_argument("--out", required=True, help="папка набора, обычно design/concepts/<набор>")
    one.add_argument("--ref", action="append", default=[], help="доп. эталон IMG или IMG=подпись")
    one.add_argument("--size")
    one.add_argument("--scene", action="store_true", help="цельная картинка без строки о белом фоне")
    batch = sub.add_parser("batch", help="список задач из JSON")
    batch.add_argument("jobs_file")
    batch.add_argument("--jobs", type=int, default=1, help="сколько задач параллельно")
    for command in (one, batch):
        command.add_argument("--provider", choices=PROVIDERS)
        command.add_argument("--no-wait", action="store_true", help="manual: не ждать файл")
        command.add_argument("--dry-run", action="store_true", help="показать вызов без генерации")
    args = parser.parse_args(argv)
    try:
        if args.cmd == "check":
            return cmd_check()
        base = {"provider": args.provider}
        if args.cmd == "one":
            spec = {"name": args.name, "prompt": args.prompt, "out": args.out, "ref": args.ref, "size": args.size, "scene": args.scene}
            jobs = [make_job(spec, base)]
        else:
            jobs = load_jobs(_abs(args.jobs_file), base)
    except GenError as error:
        say("gen", f"ОШИБКА: {error}")
        return 2
    workers = max(1, min(getattr(args, "jobs", 1), len(jobs)))
    with ThreadPoolExecutor(max_workers=workers) as pool:
        results = list(pool.map(lambda job: run_job(job, args.dry_run, not args.no_wait), jobs))
    return 1 if any(r["status"] == "error" for r in results) else 0


def build_dir(path: Path) -> None:
    """Папка в `build/`; `.gdignore` не даёт редактору Godot импортировать сырые картинки."""
    path.mkdir(parents=True, exist_ok=True)
    (WORK_DIR.parent / ".gdignore").touch()


def say(name: str, text: str) -> None:
    print(f"[{name}] {text}", flush=True)


def _abs(path: str) -> Path:
    candidate = Path(path).expanduser()
    return candidate if candidate.is_absolute() else ROOT / candidate


def _rel(path: Path) -> str:
    try:
        return str(Path(path).resolve().relative_to(ROOT))
    except ValueError:
        return str(path)


if __name__ == "__main__":
    sys.exit(main())
