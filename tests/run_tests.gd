extends SceneTree

## Headless-тесты ядра. Запуск:
##   godot --headless --path . --script res://tests/run_tests.gd

var _passed := 0
var _failed := 0
var _current := ""


func _initialize() -> void:
	var db := ContentDB.new()
	var err := db.load_all()
	if not err.is_empty():
		push_error("контент не загрузился: " + err)
		quit(1)
		return

	test_content_loads(db)
	test_stat_clamping(db)
	test_effects_and_resolvers(db)
	test_hooks_schedule_triggers(db)
	test_story_events_fire_in_order(db)
	test_crisis_grace_turn(db)
	test_crisis_defeat(db)
	test_actions(db)
	test_patron_drift(db)
	test_turn_pressure(db)
	test_full_playthrough(db)
	test_determinism(db)
	test_content_schema(db)

	print("\n--- итог: %d пройдено, %d провалено ---" % [_passed, _failed])
	quit(1 if _failed > 0 else 0)


## Страховка: если quit() не сработал, выходим на первом же кадре.
func _process(_delta: float) -> bool:
	return true


# --- микро-фреймворк ---------------------------------------------------------

func suite(name: String) -> void:
	_current = name
	print("\n[%s]" % name)


func check(condition: bool, what: String) -> void:
	if condition:
		_passed += 1
		print("  ok   %s" % what)
	else:
		_failed += 1
		print("  FAIL %s" % what)


func equal(actual, expected, what: String) -> void:
	check(actual == expected, "%s (получено %s, ожидалось %s)" % [what, str(actual), str(expected)])


# --- тесты -------------------------------------------------------------------

func test_content_loads(db: ContentDB) -> void:
	suite("Загрузка контента")
	equal(db.events.size(), 77, "всего событий (47 из .docx + 30 дополнительных)")
	equal(db.events_of_kind("random").size(), 60, "случайных событий")
	equal(db.events_of_kind("trigger").size(), 10, "триггерных событий")
	equal(db.events_of_kind("story").size(), 7, "сюжетных событий")
	equal(db.crises.size(), 4, "кризисных событий")
	equal(db.patron_events.size(), 6, "патронских событий")
	equal(db.actions.size(), 8, "действий кабинета")
	equal(db.endings.size(), 7, "концовок")
	equal(db.fatal_stats().size(), 4, "проигрышных шкал")
	check(not db.fatal_stats().has("personal"), "ЛИЧ не является проигрышной шкалой")


func test_stat_clamping(db: ContentDB) -> void:
	suite("Границы шкал")
	var state := GameState.new()
	state.setup(db.config, 1)
	equal(state.get_stat("stability"), 45, "стартовая стабильность")
	state.add_stat("stability", -100)
	equal(state.get_stat("stability"), 0, "не уходит ниже нуля")
	state.add_stat("stability", 500)
	equal(state.get_stat("stability"), 100, "не уходит выше ста")
	var real := state.add_stat("stability", 50)
	equal(real, 0, "фактическая дельта у потолка равна нулю")


func test_effects_and_resolvers(db: ContentDB) -> void:
	suite("Эффекты и динамические цели")
	var state := GameState.new()
	state.setup(db.config, 1)
	state.stats["loyalty_serb"] = 70
	state.stats["loyalty_alb"] = 20
	state.stats["loyalty_greek"] = 50

	equal(Effects.resolve(state, "loyalty_lowest"), "loyalty_alb", "самая обделённая община")
	equal(Effects.resolve(state, "loyalty_highest"), "loyalty_serb", "община у власти")

	# XVII.1 «Запретить партию» бьёт по самой обделённой общине
	var event := db.get_event("XVII")
	var choice: Dictionary = event["choices"][0]
	check(choice["dynamic_effects"].size() == 1, "у XVII.1 есть динамический эффект")
	Effects.apply(state, choice, 1.0)
	var expected := 20 - int(5 * state.effect_multiplier)
	equal(state.get_stat("loyalty_alb"), expected, "динамический -5 ушёл албанцам с учётом множителя")

	# масштабирование патронских эффектов
	var scaled := Effects._scaled(-4, 1.5)
	equal(scaled, -6, "отрицательный эффект масштабируется от нуля")
	check(state.effect_multiplier > 0.0, "множитель силы эффектов прочитан из конфига")


func test_hooks_schedule_triggers(db: ContentDB) -> void:
	suite("Хуки заметок")
	var state := GameState.new()
	state.setup(db.config, 42)
	var director := Director.new(db)

	# I.1 «Оставить памятник» → Через 6-9 ходов — Т-1
	var choice: Dictionary = db.get_event("I")["choices"][0]
	check(choice["hooks"].size() > 0, "у I.1 разобран хук из заметки")
	state.turn = 3
	director.apply_hooks(state, choice)
	equal(state.scheduled.size(), 1, "триггер взведён")
	var entry: Dictionary = state.scheduled[0]
	equal(entry["trigger"], "Т-1", "взведён именно Т-1")
	check(int(entry["turn"]) >= 9 and int(entry["turn"]) <= 12, "срок в окне 6-9 ходов от третьего хода")

	# VIII.3 → «Повышает вероятность Т-10»
	var weight_choice: Dictionary = db.get_event("VIII")["choices"][2]
	director.apply_hooks(state, weight_choice)
	check(int(state.trigger_weights.get("Т-10", 0)) > 0, "вес Т-10 поднят")

	# С-1.1 → флаг ветки
	var branch_choice: Dictionary = db.get_event("С-1")["choices"][0]
	director.apply_hooks(state, branch_choice)
	check(state.has_flag("branch_order"), "ветка «Администратор порядка» открыта")


func test_story_events_fire_in_order(db: ContentDB) -> void:
	suite("Сюжетная арка")
	var game := Game.new(db)
	game.start(7)
	var seen_story: Array = []
	for i in 60:
		if game.state.phase == GameState.Phase.OVER:
			break
		var presented := game.begin_turn()
		if not presented.is_empty():
			var code := String(presented["code"])
			if code.begins_with("С-"):
				seen_story.append([code, int(presented["turn"])])
			game.choose(_first_available(presented))
		game.end_turn()

	var codes: Array = []
	for pair in seen_story:
		codes.append(pair[0])
	equal(codes.size(), 7, "выпали все семь сюжетных событий")
	equal(codes[0], "С-1", "первым идёт С-1 «Мандат»")
	check(seen_story.size() > 0 and int(seen_story[0][1]) == 1, "С-1 приходит на первом ходу")
	var ordered := true
	for i in range(1, seen_story.size()):
		if int(seen_story[i][1]) < int(seen_story[i - 1][1]):
			ordered = false
	check(ordered, "сюжетные события идут по возрастанию хода")


func test_crisis_grace_turn(db: ContentDB) -> void:
	suite("Кризис: ход отсрочки")
	var game := Game.new(db)
	game.start(3)
	game.begin_turn()
	game.choose(1)
	game.state.stats["support"] = 0
	game.end_turn()
	equal(game.state.crisis_stat, "support", "кризис взведён, партия не окончена")
	check(not game.state.is_over(), "поражение не наступило сразу")

	var presented := game.begin_turn()
	equal(String(presented["code"]), "CR-SUP", "следующим ходом приходит кризисное событие")

	# вариант 1 требует ООН — он есть, шкала восстанавливается
	game.state.stats["un"] = 40
	game.choose(1)
	check(game.state.get_stat("support") > 0, "поддержка восстановлена")
	game.end_turn()
	equal(game.state.crisis_stat, "", "кризис снят")
	check(not game.state.is_over(), "игра продолжается")


func test_crisis_defeat(db: ContentDB) -> void:
	suite("Кризис: поражение")
	var game := Game.new(db)
	game.start(4)
	game.begin_turn()
	game.choose(1)
	game.state.stats["un"] = 0
	game.end_turn()
	equal(game.state.crisis_stat, "un", "кризис по ООН взведён")

	var presented := game.begin_turn()
	equal(String(presented["code"]), "CR-UN", "пришло кризисное событие по ООН")
	# третий вариант доступен всегда и не спасает
	game.choose(3)
	var ending := game.end_turn()
	check(game.state.is_over(), "партия окончена")
	equal(String(ending["id"]), "E-LOSS", "концовка поражения")
	check(String(ending.get("defeat_reason", "")).length() > 0, "названа причина поражения")


func test_actions(db: ContentDB) -> void:
	suite("Кабинет")
	var game := Game.new(db)
	game.start(5)
	game.begin_turn()
	game.choose(1)

	var before := game.state.get_stat("security")
	var un_before := game.state.get_stat("un")
	var result := game.do_action("act_troops")
	check(not result.has("error"), "действие применилось")
	check(game.state.get_stat("security") > before, "безопасность выросла")
	check(game.state.get_stat("un") < un_before, "одобрение ООН потрачено")

	var second := game.do_action("act_works")
	check(second.has("error"), "второе действие за ход запрещено")

	game.end_turn()
	game.begin_turn()
	game.choose(1)
	var repeat := game.do_action("act_troops")
	check(repeat.has("error"), "действие на откате недоступно")


func test_patron_drift(db: ContentDB) -> void:
	suite("Патроны")
	var game := Game.new(db)
	game.start(6)
	var director := Director.new(db)

	# спокойная община — патрон засыпает
	game.state.stats["loyalty_serb"] = 50
	game.state.stats["patron_belgrade"] = 50
	director.tick_patrons(game.state)
	check(game.state.get_stat("patron_belgrade") <= 50, "при нейтральной лояльности влияние не растёт")

	# община в глубоком минусе — патрон включается «защищать своих»
	game.state.stats["loyalty_serb"] = 10
	var before := game.state.get_stat("patron_belgrade")
	director.tick_patrons(game.state)
	check(game.state.get_stat("patron_belgrade") > before, "при низкой лояльности влияние растёт")

	# сила события масштабируется влиянием, но не безгранично
	game.state.stats["patron_belgrade"] = 100
	check(director.patron_scale(game.state, "patron_belgrade") <= 1.6, "множитель ограничен 1.6")


func test_turn_pressure(db: ContentDB) -> void:
	suite("Цена присутствия")
	var director := Director.new(db)
	var state := GameState.new()
	state.setup(db.config, 8)

	# до start_turn давление не действует
	state.turn = 1
	var un_before := state.get_stat("un")
	director.apply_turn_pressure(state)
	equal(state.get_stat("un"), un_before, "на первом ходу одобрение не тает")

	# запущенная шкала проседает именно там, где слабее всего
	state.turn = 4
	state.stats["security"] = 20
	state.stats["stability"] = 60
	var security_before := state.get_stat("security")
	var stability_before := state.get_stat("stability")
	director.apply_turn_pressure(state)
	check(state.get_stat("security") < security_before, "слабейшая шкала проседает")
	equal(state.get_stat("stability"), stability_before, "благополучная шкала не трогается")

	# за 20 ходов давление накапливается заметно
	var fresh := GameState.new()
	fresh.setup(db.config, 9)
	var un_start := fresh.get_stat("un")
	for turn in range(1, 21):
		fresh.turn = turn
		director.apply_turn_pressure(fresh)
	check(fresh.get_stat("un") < un_start - 5, "за 20 ходов одобрение ООН заметно тает (%d -> %d)"
			% [un_start, fresh.get_stat("un")])


func test_full_playthrough(db: ContentDB) -> void:
	suite("Полная партия")
	var game := Game.new(db)
	game.start(11)
	var turns := 0
	var ending := {}
	while turns < 80:
		if game.state.phase == GameState.Phase.OVER:
			break
		var presented := game.begin_turn()
		if not presented.is_empty():
			var available: Array = []
			for c in presented["choices"]:
				if c["available"]:
					available.append(int(c["index"]))
			if available.is_empty():
				check(false, "на ходу %d не осталось доступных вариантов" % game.state.turn)
				break
			game.choose(available[game.state.rng.randi_range(0, available.size() - 1)])
		ending = game.end_turn()
		turns += 1
		if not ending.is_empty():
			break
	check(not ending.is_empty(), "партия завершилась концовкой")
	check(String(ending.get("title", "")).length() > 0, "у концовки есть название: " + String(ending.get("title", "")))
	check(turns <= 31, "партия уложилась в мандат (%d ходов)" % turns)


func test_determinism(db: ContentDB) -> void:
	suite("Детерминированность")
	var first := _play_scripted(db, 99)
	var second := _play_scripted(db, 99)
	equal(first, second, "одинаковое зерно даёт одинаковую партию")
	var other := _play_scripted(db, 100)
	check(first != other, "разное зерно даёт разные партии")


## Первый доступный вариант: часть выборов заперта условиями (С-4.I требует ВЛ).
func _first_available(presented: Dictionary) -> int:
	for choice in presented["choices"]:
		if choice["available"]:
			return int(choice["index"])
	return 1


func _play_scripted(db: ContentDB, seed_value: int) -> String:
	var game := Game.new(db)
	game.start(seed_value)
	var log_parts: Array = []
	for i in 40:
		if game.state.phase == GameState.Phase.OVER:
			break
		var presented := game.begin_turn()
		if not presented.is_empty():
			log_parts.append(String(presented["code"]))
			game.choose(_first_available(presented))
		game.end_turn()
	return ",".join(log_parts)


func test_content_schema(db: ContentDB) -> void:
	suite("Целостность контента")
	var all_events: Array = db.events + db.patron_events + db.crises
	var bad_choices := 0
	var empty_text := 0
	var unknown_stats: Array = []
	var valid_keys: Array = db.stat_keys()

	for event in all_events:
		if event["choices"].size() != 3:
			bad_choices += 1
		if String(event["description"]).strip_edges().is_empty():
			empty_text += 1
		for choice in event["choices"]:
			if String(choice["outcome"]).strip_edges().is_empty():
				empty_text += 1
			for key in choice.get("effects", {}):
				if not valid_keys.has(key) and not unknown_stats.has(key):
					unknown_stats.append(key)

	equal(bad_choices, 0, "у каждого события ровно три выбора")
	equal(empty_text, 0, "нет пустых описаний и исходов")
	equal(unknown_stats, [], "все эффекты бьют по существующим шкалам")

	# Коды приходят из двух файлов (events.json и events_extra.json) —
	# совпадение кода означало бы, что одно событие молча затирает другое.
	var seen_codes: Dictionary = {}
	var duplicates: Array = []
	for event in db.events + db.patron_events + db.crises:
		var code := String(event.get("code", event.get("id", "")))
		if seen_codes.has(code):
			duplicates.append(code)
		seen_codes[code] = true
	equal(duplicates, [], "коды событий уникальны между файлами")

	# все цели хуков должны существовать
	var missing: Array = []
	for event in db.events:
		for choice in event["choices"]:
			for hook in choice.get("hooks", []):
				for code in hook.get("targets", []):
					if db.get_event(String(code)).is_empty() and not missing.has(code):
						missing.append(code)
	equal(missing, [], "все триггеры из заметок существуют")
