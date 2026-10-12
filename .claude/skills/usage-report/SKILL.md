---
name: usage-report
description: Analyze Claude usage-limit consumption for a roadmap of this project — per session, per phase and for the whole roadmap — compare it with earlier roadmaps and draw conclusions about what made work cheaper or more expensive. Use when the user asks for a usage, limits, tokens or cost analysis of a roadmap or phase, e.g. «сделай анализ расхода по родмапе 10», «сравни расход фазы 2», «сколько съел roadmap 11».
---

# Usage Report

Answer in the user's language (Russian). The numbers come from `tools/usage_report.py`; your job is to interpret them honestly, not to recompute them by hand.

## Gather

Run in one call (replace NN; for a phase question still run the whole roadmap):

```bash
python3 tools/usage_report.py NN && python3 tools/usage_report.py --history && grep -n '^Статус\|^Текущее\|сесси[ия]:' docs/roadmaps/NN-*.md
```

- If the roadmap status is «Завершён», rerun with `--save` to refresh the snapshot `docs/usage/roadmap-NN.json`. Claude Code deletes transcripts after 30 days, so snapshots are the only lasting history. Commit the snapshot with the push rule from AGENTS.md (only that file).
- If sessions are missing (no rows, or a phase without a session), say so: transcripts older than 30 days are gone, or the session ran in another worktree folder (its transcripts live under another `~/.claude/projects/` folder and are not scanned).
- Sessions listed as «не вошли в итоги» mention the roadmap but made no roadmap commit (fixes, questions). Mention them briefly; they are not part of the comparison.

## Read the numbers

- **Нагрузка** — weighted tokens at relative API prices: cache read ×0.1, cache write ×1.25, output ×5. An estimate: the subscription limit formula is not published. A Sonnet session is shown at the same weights, so it is cheaper in reality than its number.
- **На 100 строк** — load per 100 added lines in `src/`, `tests/`, `data/`. The main comparison metric, but crude: JSON data lines are cheap, UI/scene wiring across many files is expensive, closing sessions have no code at all.
- **Ср. контекст** — average context per turn. In the author's project the savings came mostly from a smaller average context, not from fewer turns.
- **Ходов/100 строк** — high values mean much orientation per unit of work (too small sessions) or heavy in-game checking.
- **База** — first-turn context: ~40k in the terminal, ~60k in the desktop Code tab.
- Behaviour lines: repeated read/edit/MCP turns in a row, single-edit turns, game launches, screenshots — adherence to AGENTS.md «Экономия контекста».

## Judge

- **Noise.** Phases of one roadmap differ by ±20% and more for the same process; never conclude from one phase. Compare roadmap to roadmap (`--history`) and phases of the same kind (core logic, UI, data, tuning).
- **Baselines.** Compare with snapshots in `docs/usage/` once there are any; until then, report absolute numbers and state the process the roadmap used (steps per session, models).
- **Process checks**, from the roadmap «План» and the report:
  - sessions follow the plan grouping (a planned «2.1 + 2.2» done as two sessions is a miss);
  - session models match `[opus]`/`[sonnet]`; for every Sonnet session check whether the next session's commits or step note fix its work — that is rework and counts against Sonnet;
  - max context stays ≤ ~200k; no single session dominates the 5-hour window;
  - one game launch per session, 1–3 screenshots;
  - base ~40k (terminal) — a 60k base means the session ran in the desktop app.
- **Causes, not just deltas.** For every notable difference name the likely cause (kind of work, session size, base, a miss in the rules) and how sure you are.

## Report

1. One-paragraph verdict: cheaper, the same, or more expensive than earlier roadmaps, and the main reason.
2. Table per phase (sessions, turns, lines, load, per 100 lines, avg/max context) and a comparison table with earlier roadmaps from `--history`.
3. What worked, what did not (process checks above), with numbers.
4. At most three concrete suggestions with expected effect and their cost to quality. Do not propose new rules when the effect is within noise; prefer removing a rule that shows no effect.
5. Caveats: estimate vs real limit, line metric, missing transcripts.

Afterwards update the project memory file about roadmap sessions with the roadmap's totals and verdict (one short paragraph).
