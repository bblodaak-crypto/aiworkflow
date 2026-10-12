extends TestCase
## Декор бесконечной локации: куски по сетке мира, одинаковые при возврате на место.


func test_chunk_index_depends_only_on_cell() -> void:
	var cell := Vector2i(-3, 7)
	assert_eq(LocationView.chunk_index(cell, 3), LocationView.chunk_index(cell, 3))
	for x: int in range(-5, 5):
		for y: int in range(-5, 5):
			var index := LocationView.chunk_index(Vector2i(x, y), 3)
			assert_true(index >= 0 and index < 3, "номер куска в пределах набора")
