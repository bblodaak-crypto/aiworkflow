#!/bin/sh
# PostToolUse: форматирует изменённый .gd-файл через gdformat (кроме prototypes/ и addons/).
# Без jq: JSON события читает Python (python3 на macOS и Linux, python или py на Windows).
py=$(command -v python3 || command -v python || command -v py) || exit 0
file=$("$py" -c 'import json, sys; print(json.load(sys.stdin).get("tool_input", {}).get("file_path", ""))' 2>/dev/null)
case "$file" in
	*/prototypes/*|*/addons/*|*\\prototypes\\*|*\\addons\\*) exit 0 ;;
	*.gd) ;;
	*) exit 0 ;;
esac
gdformat="$CLAUDE_PROJECT_DIR/.venv/bin/gdformat"
[ -x "$gdformat" ] || gdformat="$CLAUDE_PROJECT_DIR/.venv/Scripts/gdformat.exe"
[ -x "$gdformat" ] && [ -f "$file" ] || exit 0
"$gdformat" "$file" >/dev/null 2>&1 || echo "gdformat не смог отформатировать $file" >&2
exit 0
