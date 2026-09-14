extends SceneTree

## Проверка достижимости концовок. Для каждой концовки — бот, играющий именно
## на неё: веса шкал плюс жёстко заданные решения в ключевых событиях.
## Печатает долю успеха и журнал одной успешной партии.
##   godot --headless --path . --script res://tools/paths.gd -- <партий>

var db: ContentDB


func _initialize() -> void:
	db = ContentDB.new()
	var err := db.load_all()
	if not err.is_empty():
		push_error(err)
		quit(1)
		return

	var runs := 300
	for arg in OS.get_cmdline_user_args():
		if arg.is_valid_int():
			runs = arg.to_int()

	for goal in _goals():
		_probe(goal, runs)
	quit(0)


func _process(_delta: float) -> bool:
	return true


## weights — во что бот целится; forced — решения, которые он принимает всегда;
## cabinet — чинить ли просевшие шкалы между ходами.
func _goals() -> Array:
	return [
		{
			"target": "E-STATE", "name": "Государство",
			"weights": {"stability": 3.0, "security": 3.0, "support": 2.5, "un": 4.0,
					"loyalty_serb": 3.0, "loyalty_alb": 3.0, "loyalty_greek": 3.0,
					"personal": 0.6, "influence": 0.8},
			"forced": {"С-2": 1, "С-4": 2, "С-6": 2, "С-7": 1},
			"cabinet": true, "cabinet_prefer": ["act_tour", "act_payoff"],
		},
		{
			"target": "E-FRAGILE", "name": "Хрупкий мир",
			"weights": {"stability": 3.0, "security": 3.0, "un": 3.0, "support": 1.5},
			"forced": {"С-7": 2},
			"cabinet": true,
		},
		{
			"target": "E-ENRICHMENT", "name": "Обогащение",
			"weights": {"personal": 5.0, "stability": 0.8, "security": 0.8,
					"support": 0.8, "un": 0.8},
			"forced": {"С-6": 3},
			"cabinet": true, "cabinet_prefer": ["act_skim"],
		},
		{
			"target": "E-VICEROY", "name": "Наместник",
			"weights": {"influence": 5.0, "stability": 1.5, "security": 1.5},
			"forced": {"С-1": 3, "С-4": 1, "С-6": 1},
			"bands": {"support": [30, 44], "un": [32, 49]},
			"cabinet": false,
		},
		{
			"target": "E-PARTITION", "name": "Раздел",
			"weights": {"stability": 1.2, "security": 1.2, "un": 1.0,
					"loyalty_serb": 2.5, "loyalty_alb": -2.5},
			"forced": {"Т-3": 3, "Т-9": 2},
			"cabinet": true,
		},
		{
			"target": "E-LOSS", "name": "Мандат прерван",
			"weights": {"un": -3.0, "support": -2.0, "security": -2.0, "stability": -2.0},
			"forced": {},
			"cabinet": false,
		},
		{
			"target": "E-PROTECTORATE", "name": "Вечный протекторат",
			"weights": {"stability": 1.0, "un": 1.0},
			"forced": {"С-7": 3},
			"cabinet": false,
		},
	]


func _probe(goal: Dictionary, runs: int) -> void:
	var wins := 0
	var best_log: Array = []
	var best_seed := 0
	var others: Dictionary = {}
	var misses: Dictionary = {}
	var peaks: Dictionary = {}

	for i in runs:
		var result := _play(goal, i + 1)
		for key in result["peaks"]:
			peaks[key] = maxi(int(peaks.get(key, 0)), int(result["peaks"][key]))
		if String(result["ending"]) != String(goal["target"]):
			for name in result["misses"]:
				misses[name] = int(misses.get(name, 0)) + 1
		var got := String(result["ending"])
		if got == String(goal["target"]):
			wins += 1
			if best_log.is_empty():
				best_log = result["log"]
				best_seed = i + 1
		else:
			others[got] = int(others.get(got, 0)) + 1

	print("=== %s (%s) ===" % [goal["name"], goal["target"]])
	print("  достигнуто: %d из %d (%.1f%%)" % [wins, runs, 100.0 * wins / runs])
	if wins < runs:
		var parts: Array = []
		for key in others:
			parts.append("%s %d" % [key, int(others[key])])
		print("  вместо неё выпадало: " + ", ".join(parts))
		var miss_parts: Array = []
		for name in misses:
			miss_parts.append("%s — не выполнено в %d из %d" % [name, int(misses[name]), runs])
		if not miss_parts.is_empty():
			print("  какое условие срывается:")
			for line in miss_parts:
				print("    " + String(line))
		var peak_parts: Array = []
		for key in ["personal", "influence", "stability", "security", "support", "un",
				"loyalty_serb", "loyalty_alb", "loyalty_greek"]:
			peak_parts.append("%s %d" % [String(db.config["stats"][key]["short"]), int(peaks.get(key, 0))])
		print("  лучший достигнутый максимум за все партии: " + ", ".join(peak_parts))
		print("  выше всего удалось поднять САМУЮ СЛАБУЮ лояльность: %d" % int(peaks.get("min_loyalty", 0)))
	if wins == 0:
		print("")
		return

	print("  журнал успешной партии (зерно %d):" % best_seed)
	for line in best_log:
		print("    " + String(line))
	print("")


func _play(goal: Dictionary, seed_value: int) -> Dictionary:
	var game := Game.new(db)
	game.start(seed_value)
	var log_lines: Array = []

	for _i in 60:
		if game.state.phase == GameState.Phase.OVER:
			break
		var presented := game.begin_turn()
		if not presented.is_empty():
			var index := _decide(game, presented, goal)
			var code := String(presented["code"])
			var picked_text := ""
			for c in presented["choices"]:
				if int(c["index"]) == index:
					picked_text = String(c["text"])
			var result := game.choose(index)
			if not result.has("error"):
				log_lines.append("ход %2d  %-6s %-28s %s. %s" % [
					game.state.turn, code, String(presented["title"]).left(28),
					_roman(index), picked_text])
		if goal["cabinet"]:
			_act(game, goal.get("cabinet_prefer", []))
		var ending := game.end_turn()
		if not ending.is_empty() and not ending.has("error"):
			break

	var peaks: Dictionary = {}
	for key in db.stat_keys():
		peaks[key] = game.state.get_stat(String(key))
	var loyalties := game.state.loyalties_sorted()
	peaks["min_loyalty"] = int(loyalties[0][1]) if not loyalties.is_empty() else 0
	return {
		"ending": String(game.get_ending().get("id", "")),
		"log": log_lines,
		"misses": _unmet(game, String(goal["target"])),
		"peaks": peaks,
	}


## Разбирает условие целевой концовки на листья и называет невыполненные.
func _unmet(game: Game, target: String) -> Array:
	for ending in db.endings:
		if String(ending["id"]) == target:
			return _walk(game, ending["condition"])
	return []


func _walk(game: Game, condition: Dictionary) -> Array:
	var out: Array = []
	var kind := String(condition.get("type", ""))
	if kind == "all" or kind == "any":
		for sub in condition["of"]:
			out.append_array(_walk(game, sub))
		return out
	if not Effects.check(game.state, condition):
		out.append(_describe(condition))
	return out


func _describe(condition: Dictionary) -> String:
	var kind := String(condition.get("type", ""))
	match kind:
		"stat_above":
			return "%s >= %d" % [String(db.config["stats"][condition["stat"]]["short"]), int(condition["value"])]
		"stat_below":
			return "%s <= %d" % [String(db.config["stats"][condition["stat"]]["short"]), int(condition["value"])]
		"all_loyalty_above":
			return "все лояльности >= %d" % int(condition["value"])
		"final_choice":
			return "выбран С-7.%d" % int(condition["value"])
		"final_choice_in":
			return "выбран С-7.I или II"
		"choice_taken":
			return "взят %s.%d" % [String(condition["event"]), int(condition["index"])]
		"loyalty_gap_above":
			return "разрыв лояльностей >= %d" % int(condition["value"])
		"lowest_loyalty_below":
			return "низшая лояльность <= %d" % int(condition["value"])
		_:
			return kind


func _decide(game: Game, presented: Dictionary, goal: Dictionary) -> int:
	var options: Array = []
	for choice in presented["choices"]:
		if choice["available"]:
			options.append(int(choice["index"]))
	if options.is_empty():
		return 1

	var code := String(presented["code"])
	var forced: Dictionary = goal["forced"]
	if forced.has(code) and options.has(int(forced[code])):
		return int(forced[code])

	var weights: Dictionary = goal["weights"]
	var best: int = options[0]
	var best_score := -99999.0
	for index in options:
		var score := 0.0
		for candidate in game.current_event["choices"]:
			if int(candidate["index"]) != index:
				continue
			# Коридор: шкалу нужно держать в диапазоне, а не максимизировать.
			# Выше верхней границы — тянем вниз, ниже нижней — вытаскиваем вверх.
			for key in goal.get("bands", {}):
				var band: Array = goal["bands"][key]
				var delta_band := float(candidate.get("effects", {}).get(key, 0))
				var current := game.state.get_stat(String(key))
				if current > int(band[1]):
					score -= delta_band * 2.0
				elif current < int(band[0]):
					score += delta_band * 4.0
			for key in candidate.get("effects", {}):
				if not weights.has(key):
					continue
				var delta := float(candidate["effects"][key])
				var weight := float(weights[key])
				# просевшую нужную шкалу чиним в первую очередь
				if weight > 0.0 and game.state.get_stat(String(key)) < 45:
					weight *= 2.0
				score += delta * weight
		if score > best_score:
			best_score = score
			best = index
	return best


func _act(game: Game, preferred: Array) -> void:
	# Сначала действия, ради которых эта концовка и берётся: поднять слабейшую
	# лояльность или увести деньги. Без них часть концовок выглядит недостижимой.
	for id in preferred:
		for action in game.available_actions():
			if String(action["id"]) == String(id) and action["available"]:
				game.do_action(String(id))
				return
	var weakest := ""
	var weakest_value := 999
	for key in db.fatal_stats():
		if game.state.get_stat(key) < weakest_value:
			weakest_value = game.state.get_stat(key)
			weakest = key
	if weakest_value > 52:
		return
	for action in game.available_actions():
		if action["available"] and int(action["gain"].get(weakest, 0)) > 0:
			game.do_action(String(action["id"]))
			return


func _roman(index: int) -> String:
	match index:
		1: return "I"
		2: return "II"
		3: return "III"
		_: return str(index)
