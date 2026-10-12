---
name: generate-roadmap
description: Create a complete, readable, implementation-ready roadmap for a substantial feature, refactor, data migration, investigation, or architectural change in this Godot project. Use when work benefits from phased execution with explicit goals, session-sized steps, checkbox tasks, measurable completion criteria, and approval gates. For small changes, recommend a short implementation plan unless the user explicitly requests a full roadmap.
---

# Generate Roadmap

Create a roadmap that other coding agents execute step by step, each step in a fresh session that sees only the roadmap header, the phase intro, the previous step and its own step — never this conversation.

**Core principle: investigate expensively once, so every execution session is cheap.** A roadmap is written once and executed in many sessions. Spend effort on investigation here and record what you find (file paths, patterns to copy, test files) directly in the steps, so executors do not search again.

The rules, the execution procedure and the template live in [docs/roadmaps/README.md](../../../docs/roadmaps/README.md). Read it in full before writing; if it disagrees with this skill, follow the README. `make check` (`tools/roadmap_check.py`) enforces the size limits and step fields.

When the user asks only for a roadmap, write the roadmap file, add it to the README list and mention it in `docs/HANDOFF.md`; do not modify code, scenes, data, assets, `concept.md`, or `design/`.

Write in Russian unless the user asks otherwise. Keep code identifiers, paths and commands as in the repository.

## Choose the planning depth

- **Small** (localized text, value, obvious fix): offer a short plan in chat; write a roadmap only if the user insists.
- **Medium** (a few components): prefer 3–7 steps in chat unless approval gates add real value.
- **Large or architectural** (new system, `core` plus presentation, data format or saves, needs an ADR): full roadmap.

Do not invent phases or steps to look substantial.

## Investigate

1. Follow `AGENTS.md`: `docs/HANDOFF.md`, then the topic documents. Read large documents by section (`grep -n '^##'`, then offset/limit). Note each relevant `concept.md` point's status: **Утверждено**, **Рекомендация**, **Открыто**.
2. Read `docs/ARCHITECTURE.md` sections and the ADRs for the area, and the closest finished roadmap's phase summaries.
3. Find the code: classes, data files, scenes, tests, debug commands that the work touches or should imitate. For a wide or unfamiliar area, delegate the sweep to the `Explore` subagent and ask for paths with one-line roles, not file dumps; read the key files yourself.
4. For visuals, `design/ART_DIRECTION.md` (and `design/SPRITE_SPEC.md` for sprites). Asset work goes through the `make-assets` skill: a roadmap step says «набор `<тема>-v1` скиллом `make-assets`» instead of retelling its procedure.

Skip `.godot/`, `*.import`, `.venv/`, `prototypes/`. Do not invent repository facts: unverified points become open questions or a task in a step. If a missing answer changes architecture or scope, ask the user (`AskUserQuestion`, per AGENTS.md) before writing.

## Decide

- **Decisions:** only **Утверждено** points and **Принятые** ADRs, each with its source. **Рекомендация** and **Открыто** go to «Открытые вопросы» with a working value that is easy to replace (data in `data/`, a swappable class) and a note to record it in `docs/TUNABLES.md`, or a step that asks the user first.
- Do not plan changes to approved `concept.md` or `design/` decisions unless the user asked.
- A hard-to-reverse decision (data format, saves, system structure) makes the phase's first step an ADR with status «Предложено»; implementation steps come after the user accepts it.
- «Особые ограничения» lists only invariants specific to this work. General ones (`core` without nodes, determinism, tests for `core`, strict typing) are already in AGENTS.md and ARCHITECTURE.md — do not copy them.

## Design phases and steps

**Phases** are approval gates: one coherent, observable result the user can review. Order by dependency and risk: data and `core` logic with tests → `systems` → `scenes`/`ui` → tuning and documentation, unless the work needs otherwise. A phase never depends on a later phase.

**Steps** are units of work and commits; **sessions** group 1–3 consecutive steps of one phase, about 400–600 lines of code per session (smaller sessions waste limits on startup). Mark the grouping in «План» with «+» between steps of one session, and prefix every session with its model, `[opus]` or `[sonnet]`, by the README rule «Модель сессии» (Sonnet only for mechanical work on a ready pattern; mixed or doubtful sessions — opus). Each step:

- is one layer of work, about 10 changed files or fewer; a whole session fits roughly 100–150k tokens;
- leaves the repository committable: `make check` passes, the game launches;
- is self-contained: it names classes, files and data fields explicitly instead of «as above»; it may reference header decisions by name;
- lists **Файлы** from your investigation: `читать` (pattern to copy or contract to rely on; name the functions, classes or sections to read, not line numbers — they shift), `менять`, `создать` (new paths, including tests). This field is the main saving — make it concrete;
- has concrete **Задачи** (action + object + boundary), including test cases with negative and regression cases where they matter;
- has **Проверка** with step-specific evidence only (`make check` is implied). A step that changes UI, scenes or animation says «Через MCP: …» with the screen and texts to check;
- ends with an empty **Заметка** (🔲).

The last step of a phase closes it: in-game check if the phase is visible, documentation (ARCHITECTURE, GLOSSARY, ADR, TUNABLES, USER_QUEUE as needed), HANDOFF. Phase **Критерии фазы** are observable facts proving the phase result, not restated tasks and not «работает корректно». Note what cannot be checked without the target device.

Keep within the limits: header ≤ 8000 bytes, phase intro ≤ 3000, step ≤ 4000 (Cyrillic is two bytes per character). If a step does not fit, split it; if the header does not fit, shorten decisions to one line with the source instead of retelling them.

## Write

1. `docs/roadmaps/NN-kebab-case.md`, next unused number, never overwrite or renumber. Use the README template exactly. Status **Черновик**, today's date, `Текущее: не начат`.
2. Link repository files relative to the roadmap (`../../src/core/...`). Use `docs/GLOSSARY.md` terms; `concept.md` wins on conflicts.
3. Add a row to the README «Список». In `docs/HANDOFF.md` «Следующие шаги», add one item asking the user to review the roadmap, with a link — do not copy phases.
4. Run `make check` (at least `make roadmap-check`).

Do not mark any task, criterion or note complete in a new roadmap.

## Final response

In the user's language:

1. the file path;
2. one sentence per phase with its number of steps;
3. assumptions and open questions with their `concept.md` sections;
4. confirmation that nothing was implemented;
5. the model of the first session and its prompt in a code block, for example «**Первая сессия — Opus** (`claude --model opus`)» and then:

   ```
   Roadmap NN одобрен. Roadmap NN, фаза 1, шаги 1.1–1.2 — <название>. Выполни по docs/roadmaps/NN-name.md.
   ```
