@tool
class_name LocationChunk
extends Node2D
## Кусок декора локации: объекты окружения внутри квадрата от (0, 0) до `size`.
## `LocationView` раскладывает такие куски по сетке бесконечного мира вплотную друг
## к другу. В редакторе видна рамка куска: опора каждого объекта должна лежать внутри неё.

const GUIDE_COLOR := Color(0.35, 0.22, 0.1, 0.5)

## Сторона куска; совпадает с `chunk_size` локации.
@export var size := 1200.0:
	set(value):
		size = value
		queue_redraw()


func _ready() -> void:
	y_sort_enabled = true


func _draw() -> void:
	if Engine.is_editor_hint():
		draw_rect(Rect2(0, 0, size, size), GUIDE_COLOR, false, 4.0)
