extends SceneTree

## Рендерит скриншоты интерфейса без ручного запуска редактора. Нужен
## виртуальный дисплей, headless-режим не рисует:
##   xvfb-run -a -s "-screen 0 1280x800x24" godot --path . \
##     --resolution 1280x800 --script res://tools/screenshot.gd
## Кладёт shot_event.png и shot_cabinet.png в корень проекта.

var _main: Control
var _frames := 0

func _initialize() -> void:
	pass

func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 1:
		var packed: PackedScene = load("res://scenes/main.tscn")
		_main = packed.instantiate()
		_main.set_anchors_preset(Control.PRESET_FULL_RECT)
		root.add_child(_main)
		return false
	if _frames == 4:
		# экран первого события мандата
		var img := root.get_texture().get_image()
		img.save_png("res://shot_event.png")
		# нажимаем первый доступный выбор, чтобы снять экран исхода с кабинетом
		for child in _buttons(_main._choice_box):
			if not child.disabled:
				child.pressed.emit()
				break
		return false
	if _frames == 7:
		var img := root.get_texture().get_image()
		img.save_png("res://shot_cabinet.png")
		return true
	return false

func _buttons(node: Node) -> Array:
	var out: Array = []
	for child in node.get_children():
		if child is Button: out.append(child)
		else: out.append_array(_buttons(child))
	return out
