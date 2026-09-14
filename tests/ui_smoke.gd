extends SceneTree

## Дымовой тест интерфейса: собирает сцену и проходит полную партию,
## нажимая настоящие кнопки. Ловит ошибки времени выполнения, которые
## тесты ядра не видят. Запуск:
##   godot --headless --path . --script res://tests/ui_smoke.gd

var _errors := 0


## Дерево сцены готово не в _initialize, а только к первому кадру — иначе
## добавленный узел не попадает в дерево и _ready не вызывается.
func _process(_delta: float) -> bool:
	_run()
	return true


func _run() -> void:
	var packed: PackedScene = load("res://scenes/main.tscn")
	if packed == null:
		print("FAIL сцена не загрузилась")
		quit(1)
		return

	var main: Control = packed.instantiate()
	root.add_child(main)

	if main.game == null:
		print("FAIL игра не инициализировалась")
		quit(1)
		return
	print("ok   сцена собрана, партия начата")

	var turns := 0
	while turns < 45:
		if main.mode == main.Mode.ENDING:
			break
		var pressed := _press_first_enabled(main._choice_box)
		if not pressed and main.mode == main.Mode.EVENT:
			print("FAIL на ходу %d нет ни одной доступной кнопки выбора" % main.game.state.turn)
			_errors += 1
			break
		# каждый третий ход пробуем что-нибудь из кабинета
		if turns % 3 == 0:
			_press_first_enabled(main._cabinet_box)
		if not _press_first_enabled(main._footer):
			break
		turns += 1

	print("ok   сыграно ходов: %d" % turns)
	if main.mode == main.Mode.ENDING:
		print("ok   показан экран концовки: %s" % main._title_label.text)
		if main._body.text.strip_edges().is_empty():
			print("FAIL текст концовки пуст")
			_errors += 1
	else:
		print("FAIL партия не дошла до концовки")
		_errors += 1

	if main._stats_box.get_child_count() == 0:
		print("FAIL панель показателей пуста")
		_errors += 1
	else:
		print("ok   панель показателей отрисована (%d строк)" % main._stats_box.get_child_count())

	print("\n--- дымовой тест интерфейса: %s ---" % ("провален" if _errors > 0 else "пройден"))
	quit(1 if _errors > 0 else 0)


## Нажимает первую активную кнопку в контейнере. Возвращает, нашлась ли такая.
func _press_first_enabled(container: Node) -> bool:
	for child in _all_buttons(container):
		if not child.disabled:
			child.pressed.emit()
			return true
	return false


func _all_buttons(node: Node) -> Array:
	var out: Array = []
	for child in node.get_children():
		if child is Button:
			out.append(child)
		else:
			out.append_array(_all_buttons(child))
	return out
