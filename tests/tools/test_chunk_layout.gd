extends TestCase
## Раскладка куска локации в JSON (tools/chunk_layout.gd): проверки, сборка сцены и экспорт.

const ChunkLayout := preload("res://tools/chunk_layout.gd")
## Объект-заглушка для раскладок: настоящие объекты появятся с первым набором ассетов.
const BARREL := "res://tests/fixtures/props/barrel.tscn"
const CRATE := "res://tests/fixtures/props/crate.tscn"


func test_valid_layout_passes() -> void:
	assert_eq(
		ChunkLayout.validate(_layout([_prop("barrel", 100, 100), _prop("crate", 300, 100)])), []
	)


func test_anchor_outside_chunk_fails() -> void:
	var problems := ChunkLayout.validate(_layout([_prop("barrel", 100, 1250)]))
	assert_eq(problems.size(), 1)
	assert_true(problems[0].begins_with("Barrel1 (%s): опора" % BARREL), problems[0])


func test_missing_scene_fails() -> void:
	var problems := ChunkLayout.validate(_layout([_prop("no_such_prop", 100, 100)]))
	assert_eq(problems.size(), 1)
	assert_true(problems[0].contains("нет сцены"), problems[0])


func test_close_props_fail_with_names() -> void:
	var near := ChunkLayout.MIN_GAP - 1.0
	var problems := ChunkLayout.validate(
		_layout([_prop("barrel", 100, 100), _prop("barrel", 100 + near, 100)])
	)
	assert_eq(problems.size(), 1)
	assert_true(problems[0].begins_with("Barrel2 (%s): ближе" % BARREL), problems[0])
	assert_true(problems[0].ends_with("Barrel1"), problems[0])


func test_malformed_layout_fails() -> void:
	assert_eq(ChunkLayout.validate({"props": []}), ["size: нужно положительное число"])
	var problems := ChunkLayout.validate(_layout([{"scene": BARREL, "x": "1"}]))
	assert_true(problems[0].ends_with("x и y — числа"), problems[0])


func test_flip_and_size_survive_round_trip() -> void:
	var layout := _layout([_prop("barrel", 100, 100), _prop("barrel", 400, 500)])
	layout["size"] = 1000
	layout["props"][1]["flip"] = true
	var text := ChunkLayout.to_scene_text(layout, "ChunkX")
	assert_true(text.contains("size = 1000.0"), "размер куска не по умолчанию")
	assert_true(text.contains("scale = Vector2(-1, 1)"), "отражённый объект")
	var chunk: Node = _scene_from_text(text).instantiate()
	var result := ChunkLayout.from_chunk(chunk)
	chunk.free()
	assert_eq(result["problems"], [])
	var exported: Dictionary = result["layout"]
	assert_eq(ChunkLayout.to_json_text(exported), ChunkLayout.to_json_text(layout))


func test_export_rejects_renamed_node() -> void:
	var text := ChunkLayout.to_scene_text(_layout([_prop("barrel", 100, 100)]), "ChunkX")
	var chunk: Node = _scene_from_text(text.replace("Barrel1", "Keg")).instantiate()
	var result := ChunkLayout.from_chunk(chunk)
	chunk.free()
	assert_eq(result["problems"], ["Keg: имя не по сцене, ждём Barrel1"])


func _layout(props: Array) -> Dictionary:
	return {"size": 1200, "props": props}


func _prop(scene: String, x: float, y: float) -> Dictionary:
	if scene == "barrel":
		scene = BARREL
	elif scene == "crate":
		scene = CRATE
	return {"scene": scene, "x": x, "y": y}


func _scene_from_text(text: String) -> PackedScene:
	var path := "user://test_chunk_layout.tscn"
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(text)
	file.close()
	return ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
