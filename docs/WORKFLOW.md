# Рабочий процесс

Инструменты, сборка и порядок работы агентов. Правила — в [AGENTS.md](../AGENTS.md); здесь — подробности и настройки.

## Генерация ассетов

Claude генерирует ассеты сам ([ADR-0001](decisions/0001-asset-generation-pipeline.md), скилл `make-assets`): `tools/art/gen.py` вызывает `codex exec` со встроенным `image_gen` (ChatGPT по подписке, без ключа API). Эталон `design/reference/style.png` прикладывается первым всегда; без него `gen.py` отказывается работать. Фон — ровный белый, его снимает `tools/image_matte.gd`.

Подготовка (один раз): установить Codex CLI (`npm i -g @openai/codex`) и войти в него (`codex login`, аккаунт ChatGPT с подпиской).

- `python3 tools/art/gen.py check` — вошёл ли Codex и есть ли эталон.
- `python3 tools/art/gen.py one NAME PROMPT --out design/concepts/<набор> [--ref IMG[=подпись]]… [--size WxH] [--scene]` — одна картинка `<набор>/NAME.png`; PROMPT — текст или файл. Прежний файл с тем же именем уходит в `build/art/old/`. `--scene` — цельная картинка (концепт локации, плитка земли): без строки о белом фоне.
- `python3 tools/art/gen.py batch JOBS.json [--jobs N]` — список задач `{"name", "prompt", "out", "ref", "size", "provider"}`; пакеты по 1–4 из-за лимита подписки.
- `--dry-run` показывает вызов без генерации; `--provider manual` пишет заявку в `build/art/requests/` и ждёт файл от пользователя (`--no-wait` — не ждать, повторный запуск подхватит).

Каждая удачная генерация дописывает промпт, эталоны и ответ (файл, сессия Codex, время) в `PROMPTS.md` папки набора. Логи `codex exec` — `build/art-logs/<имя>.log`, рабочие файлы и неудачные попытки — `build/art/` (оба не в git). Тесты — `make art-test` (входит в `make check`), с подставным `codex`.

Наблюдения автора шаблона (Codex CLI 0.160): одна картинка — около 55–110 с и ~25 тыс. токенов Codex; размер `image_gen` выбирает сам (просили 1024×1024 — пришло 1254×1254, RGB без альфы), поэтому нарезка не полагается на точный холст. Лист 3×2 даёт объекты крупнее, чем 4×3: масштаб подбирать по ширине прежних объектов той же темы. Набор из 12 объектов с тремя кусками локации и проверкой в игре — около 30–40 мин.

**Расход по наборам** (сюда дописывать после каждого набора: число генераций, неудач, время, с какого раза подошёл масштаб).

- Пока нет.

## Инструменты Claude Code для Godot

- **GDScript LSP** — плагин `gdscript-lsp@claude-godot-tools` (маркетплейс `minami110/claude-godot-tools`, включён в `.claude/settings.json` вместе с `ENABLE_LSP_TOOL=true`). Даёт Claude диагностику типов, переход к определению и поиск ссылок по `.gd`. Мост к LSP редактора Godot на порту 6005: его даёт фоновый headless-редактор (`make lsp`, остановить — `make lsp-stop`) или открытый редактор Godot. Хук `SessionStart` в `.claude/settings.json` запускает `make -s lsp` при старте каждой сессии Claude. Если хук не сработал, Claude проверяет порт в начале работы и запускает `make lsp` (AGENTS.md, «Перед началом работы»), но инструмент LSP подхватит его только в следующей сессии.
- **godot-mcp-runtime** — MCP-сервер `godot` в пользовательском конфиге (`~/.claude.json`): `npx -y godot-mcp-runtime`, в `env` — `GODOT_PATH` (путь к Godot) и `GODOT_MCP_DISABLE_ELICITATION=true`. Запускает игру, делает скриншоты, симулирует ввод, находит UI-элементы, выполняет GDScript в запущенной игре. На время запуска сам добавляет автолоад `McpBridge` и убирает его после остановки. После правки конфига приложение Claude нужно перезапустить.
- **Хук форматирования** — `.claude/hooks/format_gd.sh` после каждой правки `.gd` запускает `gdformat` (нужен `make setup`).

### Проверка в игре через MCP

**Порядок:**

1. `run_project` — ответ «MCP bridge is ready» значит, что мост поднят.
2. Подготовить состояние и открыть нужный экран через `run_script` (ниже).
3. `get_ui_elements` (можно с `filter: "Label"`) — видимые контролы с текстом и прямоугольником. Тексты, числа и наличие кнопок проверять так: это дешевле скриншота.
4. `take_screenshot`: `responseMode: "full"` — сразу посмотреть, `"path_only"` — только файл. Рантайм-инструменты не вызывать параллельно: второй запрос отклоняется («another command is in flight»).
5. `stop_project` — возвращает лог и ошибки; автолоад моста убирается из `project.godot`.

**`run_script`.** Скрипт — `extends RefCounted` с `func execute(scene_tree: SceneTree) -> Variant`; компилируется с предупреждениями проекта как ошибками, поэтому переменные и итераторы `for` типизировать. `load()` — только с буквальным путём `res://…`, иначе мост отказывается запускать скрипт. Не делать `await` — мост рвётся.

**Если клики `simulate_input` не доходят до контролов** (бывает при растяжке окна), тап подаётся через `run_script` в координатах интерфейса (центр прямоугольника из `get_ui_elements`):

```gdscript
extends RefCounted


func execute(scene_tree: SceneTree) -> Variant:
	var root := scene_tree.root
	var at := root.get_final_transform() * Vector2(188, 54)  # координаты интерфейса
	for pressed: bool in [true, false]:
		var event := InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = pressed
		event.position = at
		event.global_position = at
		root.push_input(event)
	return at
```

**Чтобы строгая типизация не ломала мост**, папка `.mcp` исключена из предупреждений GDScript (`debug/gdscript/warnings/directory_rules` в `project.godot`), из gdtoolkit (`gdformatrc`, `gdlintrc`) и из git.

**Неполадки:**

- `run_project` отвечает «Godot project started in debug mode», а рантайм-инструменты — «No active runtime session»: в сессии второй сервер с именем `godot` (например, `@coding-solo/godot-mcp` из `~/Library/Application Support/Claude/claude_desktop_config.json`). Убрать дубль из конфига и перезапустить приложение.
- `run_project` отвечает «User declined run_project», хотя окна подтверждения не было: нужна `GODOT_MCP_DISABLE_ELICITATION=true` в `env` сервера.
- Мост не отвечает: `attach_project`, а игру запустить вручную сразу после вызова (`Godot --path .`); после работы — `detach_project`.

## Анализ расхода лимитов

`python3 tools/usage_report.py NN` — расход roadmap NN по записям сессий Claude Code и git: сессии, фазы, итоги, поведение агента (повторы ходов, запуски игры, скриншоты). Нагрузка — оценка по относительной цене API, не показания лимита подписки. `--save` пишет снимок в `docs/usage/roadmap-NN.json`, `--history` сравнивает все снимки. Записи сессий Claude Code удаляет через 30 дней, поэтому снимок закрытого roadmap — единственная долгая история. Выводы делает скилл `usage-report` («сделай анализ расхода по родмапе NN»).
