extends SceneTree

## Рендерит скриншоты интерфейса без ручного запуска редактора. Нужен
## виртуальный дисплей, headless-режим не рисует:
##   xvfb-run -a -s "-screen 0 1600x900x24" godot --path . \
##     --resolution 1600x900 --script res://tools/screenshot.gd
## Кладёт shot_briefing / shot_event / shot_cabinet / shot_help в корень проекта.

var _main: Control
var _frames := 0
var _steps: Array = []


func _initialize() -> void:
	SaveGame.clear()   # иначе вместо инструктажа снимется экран продолжения
	_steps = [
		{"shot": ""},                       # кадр на сборку сцены
		{"shot": "briefing", "then": "dismiss"},
		{"shot": ""},
		{"shot": "event", "then": "choose"},
		{"shot": ""},
		{"shot": "cabinet", "then": "play"},
		{"shot": ""},
		{"shot": "help"},
	]


func _process(_delta: float) -> bool:
	if _frames == 0:
		var packed: PackedScene = load("res://scenes/main.tscn")
		_main = packed.instantiate()
		_main.set_anchors_preset(Control.PRESET_FULL_RECT)
		root.add_child(_main)
		_frames += 1
		return false

	var step: Dictionary = _steps[mini(_frames, _steps.size() - 1)]
	var name := String(step.get("shot", ""))
	if not name.is_empty():
		root.get_texture().get_image().save_png("res://shot_%s.png" % name)

	match String(step.get("then", "")):
		"dismiss", "choose":
			_press(_main._choice_box)
		"play":
			for i in 4:
				_press(_main._choice_box)
				_press(_main._footer)
			_main._help_button.pressed.emit()

	_frames += 1
	return _frames > _steps.size()


func _press(container: Node) -> void:
	for child in _buttons(container):
		if not child.disabled:
			child.pressed.emit()
			return


func _buttons(node: Node) -> Array:
	var out: Array = []
	for child in node.get_children():
		if child is Button:
			out.append(child)
		else:
			out.append_array(_buttons(child))
	return out
