class_name LocationView
extends Node2D
## Оформление локации: земля и декор. Мир бесконечный, поэтому декор задан
## кусками — сценами `LocationChunk` размером `chunk_size`, которые раскладываются по сетке
## мира. Кусок клетки выбирается по её координатам: при возврате на место декор тот же.
## Корень и `Props` — y-sort: объекты сортируются по высоте вместе с персонажами арены.

## Запас вокруг видимой области: высокий объект у края соседнего куска не появляется рывком.
const MARGIN := 200.0

@export var chunks: Array[PackedScene] = []
@export var chunk_size := 1200.0

var _placed: Dictionary[Vector2i, Node2D] = {}

@onready var _ground: EndlessGround = $Ground
@onready var _props: Node2D = $Props


## Номер куска для клетки сетки: зависит только от клетки.
static func chunk_index(cell: Vector2i, count: int) -> int:
	return posmod(hash(cell), count)


## Видимая область мира: рисуется и держит декор только она.
func show_area(rect: Rect2) -> void:
	_ground.view_rect = rect
	if chunks.is_empty():
		return
	var area := rect.grow(MARGIN)
	var first := Vector2i((area.position / chunk_size).floor())
	var last := Vector2i((area.end / chunk_size).floor())
	var wanted: Dictionary[Vector2i, bool] = {}
	for x: int in range(first.x, last.x + 1):
		for y: int in range(first.y, last.y + 1):
			var cell := Vector2i(x, y)
			wanted[cell] = true
			if not _placed.has(cell):
				_place(cell)
	for cell: Vector2i in _placed.keys():
		if not wanted.has(cell):
			_placed[cell].queue_free()
			_placed.erase(cell)


## Сколько кусков сейчас стоит в мире.
func placed_count() -> int:
	return _placed.size()


func _place(cell: Vector2i) -> void:
	var chunk := chunks[chunk_index(cell, chunks.size())].instantiate() as Node2D
	chunk.position = Vector2(cell) * chunk_size
	chunk.y_sort_enabled = true
	_props.add_child(chunk)
	_placed[cell] = chunk
