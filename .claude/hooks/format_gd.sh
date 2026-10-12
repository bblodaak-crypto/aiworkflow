#!/bin/sh
# PostToolUse: форматирует изменённый .gd-файл через gdformat (кроме prototypes/ и addons/).
file=$(jq -r '.tool_input.file_path // empty')
case "$file" in
	*/prototypes/*|*/addons/*) exit 0 ;;
	*.gd) ;;
	*) exit 0 ;;
esac
gdformat="$CLAUDE_PROJECT_DIR/.venv/bin/gdformat"
[ -x "$gdformat" ] && [ -f "$file" ] || exit 0
"$gdformat" "$file" >/dev/null 2>&1 || echo "gdformat не смог отформатировать $file" >&2
exit 0
