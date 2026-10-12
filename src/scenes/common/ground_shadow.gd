@tool
class_name GroundShadow
extends Node2D
## Мягкая овальная тень под персонажем, как в эталоне. `@tool` — видна в редакторе.

const COLOR := Color(0.35, 0.22, 0.1, 0.22)
const FLATTEN := 0.28

@export var radius := 30.0:
	set(value):
		radius = value
		queue_redraw()


func _draw() -> void:
	draw_set_transform(Vector2.ZERO, 0.0, Vector2(1.0, FLATTEN))
	draw_circle(Vector2.ZERO, radius, COLOR)
