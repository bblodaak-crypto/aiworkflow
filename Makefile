# Команды проекта. Подробности — в AGENTS.md.

GODOT ?= $(shell command -v godot 2>/dev/null \
	|| ls /Applications/Godot.app/Contents/MacOS/Godot 2>/dev/null \
	|| ls $(HOME)/Applications/Godot.app/Contents/MacOS/Godot 2>/dev/null \
	|| ls $(HOME)/Downloads/Godot.app/Contents/MacOS/Godot 2>/dev/null)
VENV := .venv
GD_SOURCES := .

.PHONY: setup format format-check lint import test handoff-check roadmap-check art-test assets-check catalog catalog-check toc toc-check check run lsp lsp-stop

setup:
	python3 -m venv $(VENV)
	$(VENV)/bin/pip install --quiet --upgrade pip
	$(VENV)/bin/pip install --quiet -r requirements-dev.txt

format:
	$(VENV)/bin/gdformat $(GD_SOURCES)

format-check:
	$(VENV)/bin/gdformat --check $(GD_SOURCES)

lint:
	$(VENV)/bin/gdlint $(GD_SOURCES)

# Обновляет кэш class_name; нужен после клонирования и новых классов.
import:
	@test -n "$(GODOT)" || (echo "Godot не найден, укажите GODOT=/path/to/Godot" && exit 1)
	"$(GODOT)" --headless --path . --import >/dev/null 2>&1 || true

test: import
	"$(GODOT)" --headless --path . --script res://tests/run_tests.gd

# HANDOFF читается целиком в начале каждой сессии: справка — в профильных документах.
HANDOFF_MAX_BYTES := 12000

handoff-check:
	@size=$$(wc -c < docs/HANDOFF.md | tr -d " "); \
	if [ $$size -gt $(HANDOFF_MAX_BYTES) ]; then \
		echo "docs/HANDOFF.md: $$size байт, лимит $(HANDOFF_MAX_BYTES). Перенесите справку в профильные документы (таблица «Когда что читать»)."; \
		exit 1; \
	fi

# Roadmap: размер шапки и шагов, поля шага (tools/roadmap_check.py).
roadmap-check:
	@python3 tools/roadmap_check.py docs/roadmaps

# Тесты генератора ассетов (tools/art/gen.py) — без реальной генерации, лимит подписки не тратят.
art-test:
	@python3 -m unittest discover -s tools/art -p 'test_*.py'

# Готовые ассеты по design/SPRITE_SPEC.md: поле и опора объектов, листы кадров, ореол (tools/check_assets.gd).
assets-check:
	@test -n "$(GODOT)" || (echo "Godot не найден, укажите GODOT=/path/to/Godot" && exit 1)
	@"$(GODOT)" --headless --path . --script res://tools/check_assets.gd

# Каталог ассетов docs/ASSET_CATALOG.md (tools/asset_catalog.gd): make catalog после нового объекта или врага.
catalog: import
	@"$(GODOT)" --headless --path . --script res://tools/asset_catalog.gd

catalog-check: import
	@"$(GODOT)" --headless --path . --script res://tools/asset_catalog.gd -- --check

# Оглавления больших документов (tools/doc_toc.py): make toc после правки заголовков.
# Новый большой документ — маркеры <!-- toc --> и <!-- /toc --> и строка здесь.
TOC_DOCS := concept.md docs/ARCHITECTURE.md docs/KNOWN_ISSUES.md

toc:
	python3 tools/doc_toc.py $(TOC_DOCS)

toc-check:
	@python3 tools/doc_toc.py --check $(TOC_DOCS)

check: format-check lint handoff-check roadmap-check toc-check art-test assets-check catalog-check test

run:
	@test -n "$(GODOT)" || (echo "Godot не найден, укажите GODOT=/path/to/Godot" && exit 1)
	"$(GODOT)" --path .

# Фоновый headless-редактор с GDScript LSP для Claude Code (плагин gdscript-lsp).
LSP_PORT := 6005

lsp:
	@test -n "$(GODOT)" || (echo "Godot не найден, укажите GODOT=/path/to/Godot" && exit 1)
	@if nc -z localhost $(LSP_PORT) 2>/dev/null; then echo "LSP уже слушает порт $(LSP_PORT)"; else \
		nohup "$(GODOT)" --headless --editor --path . --lsp-port $(LSP_PORT) >/dev/null 2>&1 & \
		for i in $$(seq 1 30); do nc -z localhost $(LSP_PORT) 2>/dev/null && { echo "LSP запущен на порту $(LSP_PORT)"; exit 0; }; sleep 1; done; \
		echo "LSP не поднялся за 30 с"; exit 1; fi

lsp-stop:
	@pkill -f -- "--lsp-port $(LSP_PORT)" && echo "LSP остановлен" || echo "LSP не был запущен"
