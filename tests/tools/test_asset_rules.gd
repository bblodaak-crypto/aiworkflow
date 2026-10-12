extends TestCase
## Проверка ассетов по SPRITE_SPEC (tools/asset_rules.gd) на картинках, собранных в коде.

const AssetRules := preload("res://tools/asset_rules.gd")
const STONE := Color(0.55, 0.5, 0.45)


func test_valid_prop_passes() -> void:
	assert_eq(AssetRules.check_prop(_prop(Rect2i(8, 8, 84, 64), Vector2i(100, 80))), [])


func test_prop_without_margin_fails() -> void:
	var problems := AssetRules.check_prop(_prop(Rect2i(0, 8, 92, 64), Vector2i(100, 80)))
	assert_eq(problems.size(), 1)
	assert_true(problems[0].begins_with("поле меньше"), problems[0])


func test_shifted_pivot_fails() -> void:
	var off_center := AssetRules.check_prop(_prop(Rect2i(8, 8, 70, 64), Vector2i(100, 80)))
	assert_eq(off_center.size(), 1)
	assert_true(off_center[0].begins_with("опора сдвинута"), "форма не по центру")
	var lifted := AssetRules.check_prop(_prop(Rect2i(8, 8, 84, 50), Vector2i(100, 80)))
	assert_true(lifted[0].begins_with("опора сдвинута"), "форма над нижним полем")


func test_opaque_image_fails() -> void:
	var image := Image.create_empty(100, 80, false, Image.FORMAT_RGBA8)
	image.fill(STONE)
	assert_true(AssetRules.check_prop(image)[0].begins_with("нет прозрачности"))


func test_white_halo_fails() -> void:
	var image := _prop(Rect2i(9, 9, 82, 62), Vector2i(100, 80))
	var ring := Rect2i(8, 8, 84, 64)
	for x: int in range(ring.position.x, ring.end.x):
		for y: int in range(ring.position.y, ring.end.y):
			if not Rect2i(9, 9, 82, 62).has_point(Vector2i(x, y)):
				image.set_pixel(x, y, Color(1, 1, 1, 0.5))
	var problems := AssetRules.check_prop(image)
	assert_eq(problems.size(), 1)
	assert_true(problems[0].begins_with("светлый ореол"), problems[0])


func test_soft_body_colored_edge_is_not_halo() -> void:
	var image := _prop(Rect2i(9, 9, 82, 62), Vector2i(100, 80))
	for x: int in range(8, 92):
		image.set_pixel(x, 8, Color(STONE, 0.5))
		image.set_pixel(x, 71, Color(STONE, 0.5))
	assert_almost_eq(AssetRules.halo_share(image), 0.0)


func test_seamless_tile_passes() -> void:
	var image := _tile(
		func(x: int, y: int) -> float: return sin(x * TAU / 32.0) * cos(y * TAU / 16.0)
	)
	assert_almost_eq(AssetRules.seam_error(image), 0.0, 0.01)
	assert_eq(AssetRules.check_tile(image), [])


func test_tile_with_seam_fails() -> void:
	var image := _tile(func(x: int, _y: int) -> float: return x / 32.0)
	var problems := AssetRules.check_tile(image)
	assert_true(AssetRules.seam_error(image) > AssetRules.SEAM_MAX)
	assert_eq(problems.size(), 1)
	assert_true(problems[0].begins_with("шов при повторе"), problems[0])


func test_transparent_tile_fails() -> void:
	var image := _tile(func(_x: int, _y: int) -> float: return 0.0)
	image.set_pixel(0, 0, Color(STONE, 0.5))
	assert_true(AssetRules.check_tile(image)[0].begins_with("плитка с прозрачностью"))


func test_valid_sheet_passes() -> void:
	assert_eq(AssetRules.check_sheet(_sheet(1024), _meta(2)), [])


func test_sheet_not_multiple_of_frame_fails() -> void:
	var problems := AssetRules.check_sheet(_sheet(1000), _meta(2))
	assert_true(problems.size() >= 1)
	assert_true(problems[0].begins_with("лист 1000 × 512"), problems[0])


func test_sheet_without_json_fails() -> void:
	assert_eq(AssetRules.check_sheet(_sheet(1024), null), ["нет JSON с метаданными листа"])


func test_sheet_meta_mismatch_fails() -> void:
	var meta := _meta(3)
	meta["pivot"] = [256.0, 500.0]
	var problems := AssetRules.check_sheet(_sheet(1024), meta)
	assert_eq(problems.size(), 2)
	assert_true(problems[0].begins_with("frame_count"), problems[0])
	assert_true(problems[1].begins_with("pivot"), problems[1])


func test_sheet_pivot_shifted_left_passes() -> void:
	var meta := _meta(2)
	meta["pivot"] = [190.0, 480.0]
	assert_eq(AssetRules.check_sheet(_sheet(1024), meta), [])
	meta["pivot"] = [100.0, 480.0]
	assert_eq(AssetRules.check_sheet(_sheet(1024), meta).size(), 1)
	meta["pivot"] = [300.0, 480.0]
	assert_eq(AssetRules.check_sheet(_sheet(1024), meta).size(), 1)


func test_feet_anchor_is_bottom_edge_and_lower_third_center() -> void:
	var image := Image.create_empty(100, 100, false, Image.FORMAT_RGBA8)
	# Голова смещена вправо, ноги — столбик 20..29 в нижней трети.
	image.fill_rect(Rect2i(50, 10, 40, 50), STONE)
	image.fill_rect(Rect2i(20, 60, 10, 30), STONE)
	var feet := AssetRules.feet_anchor(image)
	assert_almost_eq(feet.y, 90.0)
	assert_almost_eq(feet.x, 24.5)


func test_feet_anchor_ignores_faint_alpha() -> void:
	var image := Image.create_empty(40, 40, false, Image.FORMAT_RGBA8)
	image.fill_rect(Rect2i(10, 5, 20, 20), STONE)
	image.fill_rect(Rect2i(0, 30, 40, 5), Color(STONE, 0.2))
	assert_almost_eq(AssetRules.feet_anchor(image).y, 25.0)


func test_feet_anchor_of_empty_image_is_bottom_center() -> void:
	var image := Image.create_empty(40, 30, false, Image.FORMAT_RGBA8)
	assert_eq(AssetRules.feet_anchor(image), Vector2(20, 30))


func test_median_and_spread() -> void:
	assert_almost_eq(AssetRules.median(PackedFloat32Array([5, 1, 3])), 3.0)
	assert_almost_eq(AssetRules.median(PackedFloat32Array([4, 1, 3, 2])), 2.5)
	assert_almost_eq(AssetRules.median(PackedFloat32Array()), 0.0)
	assert_almost_eq(AssetRules.spread(PackedFloat32Array([190, 200, 210]), 200.0), 0.1)
	assert_almost_eq(AssetRules.spread(PackedFloat32Array([1, 2]), 0.0), 0.0)


func _prop(body: Rect2i, size: Vector2i) -> Image:
	var image := Image.create_empty(size.x, size.y, false, Image.FORMAT_RGBA8)
	image.fill_rect(body, STONE)
	return image


func _sheet(width: int) -> Image:
	var image := Image.create_empty(width, 512, false, Image.FORMAT_RGBA8)
	image.fill_rect(Rect2i(200, 100, 112, 380), STONE)
	return image


func _meta(frames: int) -> Dictionary:
	return {
		"frame_count": float(frames),
		"frame_size": [512.0, 512.0],
		"pivot": [256.0, 480.0],
		"fps": 8.0,
		"loop": true,
	}


## Непрозрачная плитка 32 × 32: яркость — STONE, сдвинутая на `shade(x, y)` · 0,2.
func _tile(shade: Callable) -> Image:
	var image := Image.create_empty(32, 32, false, Image.FORMAT_RGBA8)
	for x: int in 32:
		for y: int in 32:
			var offset: float = shade.call(x, y) * 0.2
			image.set_pixel(x, y, Color(STONE.r + offset, STONE.g + offset, STONE.b + offset))
	return image
