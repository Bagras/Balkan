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

	if main.mode != main.Mode.BRIEFING:
		print("FAIL новая партия не начинается с инструктажа")
		_errors += 1
	elif not main._body.text.contains("тридцать") and not main._body.text.contains("Мандат"):
		print("FAIL текст инструктажа пуст или не о мандате")
		_errors += 1
	else:
		print("ok   новая партия начинается с инструктажа")
	_dismiss_briefing(main)

	_check_help(main)

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

	_check_journal_and_resume(packed)

	print("\n--- дымовой тест интерфейса: %s ---" % ("провален" if _errors > 0 else "пройден"))
	quit(1 if _errors > 0 else 0)


## Журнал и продолжение прерванной партии: экраны, до которых обычный
## прогон партии не доходит.
func _check_journal_and_resume(packed: PackedScene) -> void:
	SaveGame.clear()
	var main: Control = packed.instantiate()
	root.add_child(main)

	_dismiss_briefing(main)
	# играем пару ходов, чтобы в журнале что-то появилось и записался автосейв
	for i in 3:
		_press_first_enabled(main._choice_box)
		_press_first_enabled(main._footer)

	var body_before: String = main._body.text
	main._journal_button.pressed.emit()
	if main._body.text == body_before:
		print("FAIL журнал не изменил содержимое экрана")
		_errors += 1
	elif not main._body.text.contains("Ход"):
		print("FAIL в журнале нет записей о ходах")
		_errors += 1
	else:
		print("ok   журнал открывается и показывает принятые решения")
	if main._choice_box.visible:
		print("FAIL при открытом журнале выборы остались видимы")
		_errors += 1

	main._journal_button.pressed.emit()
	if main._body.text != body_before or not main._choice_box.visible:
		print("FAIL возврат из журнала не восстановил экран")
		_errors += 1
	else:
		print("ok   возврат из журнала восстанавливает прежний экран")

	if not SaveGame.has_save():
		print("FAIL партия не сохранилась автоматически")
		_errors += 1
		return
	print("ok   партия сохранена автоматически")

	var turn_before: int = main.game.state.turn
	var stats_before: Dictionary = main.game.state.stats.duplicate()
	main.queue_free()

	# новая сцена при наличии сейва должна предложить продолжить
	var second: Control = packed.instantiate()
	root.add_child(second)
	if second.mode != second.Mode.TITLE:
		print("FAIL при наличии сохранения не показан экран продолжения")
		_errors += 1
		return
	print("ok   при наличии сохранения показан экран продолжения")

	if not _press_first_enabled(second._choice_box):
		print("FAIL кнопка продолжения недоступна")
		_errors += 1
		return
	if second.game.state.turn != turn_before or second.game.state.stats != stats_before:
		print("FAIL продолженная партия не совпадает с сохранённой (ход %d против %d)"
				% [second.game.state.turn, turn_before])
		_errors += 1
	else:
		print("ok   продолженная партия совпадает с сохранённой (ход %d)" % turn_before)
	SaveGame.clear()


## Инструктаж показывается один раз перед первым ходом — закрываем его.
func _dismiss_briefing(main: Control) -> void:
	if main.mode == main.Mode.BRIEFING:
		_press_first_enabled(main._choice_box)


func _check_help(main: Control) -> void:
	var before: String = main._body.text
	main._help_button.pressed.emit()
	var shown: String = main._body.text
	if shown == before:
		print("FAIL справка не открылась")
		_errors += 1
		return
	var missing: Array = []
	for word in ["Стабильность", "Одобрение ООН", "Влияние", "Белград", "кабинет"]:
		if not shown.contains(word):
			missing.append(word)
	if not missing.is_empty():
		print("FAIL в справке нет разделов: " + ", ".join(missing))
		_errors += 1
	else:
		print("ok   справка объясняет шкалы, патронов и кабинет")
	main._help_button.pressed.emit()
	if main._body.text != before:
		print("FAIL возврат из справки не восстановил экран")
		_errors += 1
	else:
		print("ok   возврат из справки восстанавливает экран")

	# подсказки должны стоять на строках шкал
	var with_tips := 0
	for child in main._stats_box.get_children():
		if child is Control and not String(child.tooltip_text).is_empty():
			with_tips += 1
	if with_tips < 12:
		print("FAIL подсказок на шкалах только %d, ожидалось 12" % with_tips)
		_errors += 1
	else:
		print("ok   у всех двенадцати шкал есть подсказка (%d)" % with_tips)


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
