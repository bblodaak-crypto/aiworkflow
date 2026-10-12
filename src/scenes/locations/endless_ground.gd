@tool
class_name EndlessGround
extends Node2D
## Бесконечная земля: спокойный фон и редкие крупные мягкие пятна, по которым видно
## движение камеры. Пятна зависят только от клетки сетки, поэтому земля одна и та же
## при возврате на место. Рисуется только видимая область `view_rect`; в редакторе —
## область размером с экран вокруг начала координат. С текстурой `texture` фон —
## бесшовная плитка по сетке мира, пятна поверх — по `draw_patches`.

const EDITOR_PREVIEW := Rect2(-240, -430, 480, 860)

## Бесшовная плитка земли; без неё фон — `base_color`.
@export var texture: Texture2D:
	set(value):
		texture = value
		queue_redraw()
## Масштаб плитки: 0,25 — 4 px картинки на игровую единицу, как у спрайтов.
@export var texture_scale := 0.25:
	set(value):
		texture_scale = maxf(value, 0.01)
		queue_redraw()
## Рисовать пятна и камешки поверх текстуры (без текстуры рисуются всегда).
@export var draw_patches := false:
	set(value):
		draw_patches = value
		queue_redraw()

@export var base_color := Color("ead3a8"):
	set(value):
		base_color = value
		queue_redraw()
@export var patch_color := Color("e2c796"):
	set(value):
		patch_color = value
		queue_redraw()
@export var pebble_color := Color("d6b886"):
	set(value):
		pebble_color = value
		queue_redraw()
## Сторона клетки, в каждой клетке одно пятно и несколько камешков.
@export var cell := 240.0:
	set(value):
		cell = maxf(value, 16.0)
		queue_redraw()
@export var patch_radius_min := 40.0:
	set(value):
		patch_radius_min = value
		queue_redraw()
@export var patch_radius_max := 90.0:
	set(value):
		patch_radius_max = value
		queue_redraw()
## Сплющивание пятен по вертикали: вид сверху под углом.
@export var patch_flatten := 0.45:
	set(value):
		patch_flatten = value
		queue_redraw()
@export var pebbles_max := 3:
	set(value):
		pebbles_max = value
		queue_redraw()
@export var pebble_radius := 4.0:
	set(value):
		pebble_radius = value
		queue_redraw()

## Видимая область в координатах мира.
var view_rect := Rect2():
	set(value):
		if value != view_rect:
			view_rect = value
			queue_redraw()


func _draw() -> void:
	var area := EDITOR_PREVIEW if Engine.is_editor_hint() else view_rect
	if texture == null:
		draw_rect(area.grow(cell), base_color)
	else:
		_draw_tiles(area)
		if not draw_patches:
			return
	var first := (area.position / cell).floor() - Vector2.ONE
	var last := (area.end / cell).ceil()
	var rng := RandomNumberGenerator.new()
	for x in range(int(first.x), int(last.x) + 1):
		for y in range(int(first.y), int(last.y) + 1):
			_draw_cell(Vector2i(x, y), rng)


func _draw_tiles(area: Rect2) -> void:
	var tile := texture.get_size() * texture_scale
	var first := (area.position / tile).floor()
	var last := (area.end / tile).ceil()
	for x in range(int(first.x), int(last.x)):
		for y in range(int(first.y), int(last.y)):
			draw_texture_rect(texture, Rect2(Vector2(x, y) * tile, tile), false)


func _draw_cell(at: Vector2i, rng: RandomNumberGenerator) -> void:
	rng.seed = hash(at)
	var origin := Vector2(at) * cell
	var patch_center := origin + Vector2(rng.randf(), rng.randf()) * cell
	var patch_radius := rng.randf_range(patch_radius_min, patch_radius_max)
	draw_set_transform(patch_center, 0.0, Vector2(1.0, patch_flatten))
	draw_circle(Vector2.ZERO, patch_radius, patch_color)
	draw_set_transform(Vector2.ZERO)
	for i in rng.randi_range(0, pebbles_max):
		var pebble := origin + Vector2(rng.randf(), rng.randf()) * cell
		draw_set_transform(pebble, 0.0, Vector2(1.0, 0.6))
		draw_circle(Vector2.ZERO, pebble_radius * rng.randf_range(0.6, 1.2), pebble_color)
	draw_set_transform(Vector2.ZERO)
