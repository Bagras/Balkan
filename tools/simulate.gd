extends SceneTree

## Симулятор баланса. Прогоняет партии разными стратегиями и печатает,
## куда сходится игра. Запуск:
##   godot --headless --path . --script res://tools/simulate.gd -- <партий>

const POLICIES := ["random", "safe", "corrupt", "loyal"]

var db: ContentDB


func _initialize() -> void:
	db = ContentDB.new()
	var err := db.load_all()
	if not err.is_empty():
		push_error(err)
		quit(1)
		return

	var runs := 400
	for arg in OS.get_cmdline_user_args():
		if arg.is_valid_int():
			runs = arg.to_int()

	print("Симуляция: %d партий на стратегию\n" % runs)
	for policy in POLICIES:
		_report(policy, _run_many(policy, runs))
	quit(0)


func _process(_delta: float) -> bool:
	return true


func _run_many(policy: String, runs: int) -> Dictionary:
	var endings: Dictionary = {}
	var defeats: Dictionary = {}
	var turns_total := 0
	var stat_totals: Dictionary = {}
	var random_seen_total := 0
	var trigger_fires: Dictionary = {}
	var crises_total := 0
	var min_totals: Dictionary = {}
	var gate_pass: Dictionary = {"стаб>=50": 0, "без>=50": 0, "под>=50": 0, "оон>=50": 0, "все четыре": 0}

	for i in runs:
		var result := _play(policy, i + 1)
		var ending_title := String(result["ending"].get("title", "—"))
		endings[ending_title] = int(endings.get(ending_title, 0)) + 1
		if result["ending"].get("kind", "") == "loss":
			var cause := String(result["defeat_stat"])
			defeats[cause] = int(defeats.get(cause, 0)) + 1
		turns_total += int(result["turns"])
		random_seen_total += int(result["random_seen"])
		for key in result["stats"]:
			stat_totals[key] = int(stat_totals.get(key, 0)) + int(result["stats"][key])
		for code in result["triggers"]:
			trigger_fires[code] = int(trigger_fires.get(code, 0)) + 1
		crises_total += int(result["crises"])
		for key in result["minimums"]:
			min_totals[key] = int(min_totals.get(key, 0)) + int(result["minimums"][key])
		var all_four := true
		for pair in [["стаб>=50", "stability"], ["без>=50", "security"], ["под>=50", "support"], ["оон>=50", "un"]]:
			if int(result["stats"][pair[1]]) >= 50:
				gate_pass[pair[0]] = int(gate_pass[pair[0]]) + 1
			else:
				all_four = false
		if all_four:
			gate_pass["все четыре"] = int(gate_pass["все четыре"]) + 1

	return {
		"runs": runs, "endings": endings, "defeats": defeats,
		"avg_turns": float(turns_total) / runs,
		"avg_random_seen": float(random_seen_total) / runs,
		"avg_stats": stat_totals, "triggers": trigger_fires,
		"avg_crises": float(crises_total) / runs, "min_stats": min_totals, "gates": gate_pass,
	}


func _play(policy: String, seed_value: int) -> Dictionary:
	var game := Game.new(db)
	game.start(seed_value)
	var triggers: Array = []
	var crises := 0
	var minimums: Dictionary = {}
	for key in db.fatal_stats():
		minimums[key] = 100

	for _i in 60:
		if game.state.phase == GameState.Phase.OVER:
			break
		var presented := game.begin_turn()
		if not presented.is_empty():
			var code := String(presented["code"])
			if code.begins_with("Т-") or code.begins_with("P-") or code.begins_with("CR-"):
				triggers.append(code)
			game.choose(_decide(game, presented, policy))
		_maybe_act(game, policy)
		for key in db.fatal_stats():
			minimums[key] = mini(int(minimums[key]), game.state.get_stat(key))
		var had_crisis := not game.state.crisis_stat.is_empty()
		var ending := game.end_turn()
		if not had_crisis and not game.state.crisis_stat.is_empty():
			crises += 1
		if not ending.is_empty() and not ending.has("error"):
			break

	var random_seen := 0
	for entry in game.state.history:
		var event := db.get_event(String(entry["event"]))
		if not event.is_empty() and event.get("kind", "") == "random":
			random_seen += 1

	return {
		"ending": game.get_ending(),
		"defeat_stat": game.state.defeat_reason,
		"turns": game.state.turn,
		"stats": game.state.stats,
		"random_seen": random_seen,
		"triggers": triggers,
		"crises": crises,
		"minimums": minimums,
	}


## Стратегии-боты. Оценивают вариант по сумме эффектов с разными весами.
func _decide(game: Game, presented: Dictionary, policy: String) -> int:
	var options: Array = []
	for choice in presented["choices"]:
		if choice["available"]:
			options.append(int(choice["index"]))
	if options.is_empty():
		return 1
	if policy == "random":
		return options[game.state.rng.randi_range(0, options.size() - 1)]

	var best: int = options[0]
	var best_score := -9999.0
	for index in options:
		var raw := _raw_choice(game, index)
		var score := _score(game, raw, policy)
		if score > best_score:
			best_score = score
			best = index
	return best


func _raw_choice(game: Game, index: int) -> Dictionary:
	for choice in game.current_event["choices"]:
		if int(choice["index"]) == index:
			return choice
	return {}


func _score(game: Game, choice: Dictionary, policy: String) -> float:
	var effects: Dictionary = choice.get("effects", {})
	var score := 0.0
	for key in effects:
		var delta := float(effects[key])
		match policy:
			"safe":
				# бережёт проигрышные шкалы, особенно те, что уже просели
				if key in ["stability", "un", "security", "support"]:
					var current := float(game.state.get_stat(key))
					score += delta * (2.5 if current < 40.0 else 1.0)
			"corrupt":
				if key == "personal":
					score += delta * 3.0
				elif key in ["stability", "un", "security", "support"]:
					score += delta * 0.6
			"loyal":
				if key.begins_with("loyalty_"):
					score += delta * 2.0
				elif key in ["stability", "un", "security", "support"]:
					score += delta * 0.8
	return score


func _maybe_act(game: Game, policy: String) -> void:
	if policy == "random":
		return
	# чиним самую просевшую проигрышную шкалу, если есть чем
	var weakest := ""
	var weakest_value := 999
	for key in db.fatal_stats():
		if game.state.get_stat(key) < weakest_value:
			weakest_value = game.state.get_stat(key)
			weakest = key
	if weakest_value > 45:
		return
	for action in game.available_actions():
		if not action["available"]:
			continue
		if int(action["gain"].get(weakest, 0)) > 0:
			game.do_action(String(action["id"]))
			return


func _report(policy: String, data: Dictionary) -> void:
	var runs := int(data["runs"])
	print("=== стратегия: %s ===" % policy)
	print("  средняя длительность: %.1f ходов, случайных событий за партию: %.1f из %d"
			% [data["avg_turns"], data["avg_random_seen"], db.events_of_kind("random").size()])

	var ending_lines: Array = []
	for title in data["endings"]:
		ending_lines.append([title, int(data["endings"][title])])
	ending_lines.sort_custom(func(a, b): return a[1] > b[1])
	print("  концовки:")
	for line in ending_lines:
		print("    %-22s %5.1f%%" % [line[0], 100.0 * float(line[1]) / runs])

	if not data["defeats"].is_empty():
		var parts: Array = []
		for cause in data["defeats"]:
			parts.append("%s %.1f%%" % [cause, 100.0 * float(data["defeats"][cause]) / runs])
		print("  причины поражения: " + ", ".join(parts))

	var stat_parts: Array = []
	for key in ["stability", "un", "security", "support", "influence", "personal",
			"loyalty_serb", "loyalty_alb", "loyalty_greek"]:
		stat_parts.append("%s %.0f" % [db.config["stats"][key]["short"], float(data["avg_stats"].get(key, 0)) / runs])
	print("  средние итоговые шкалы: " + ", ".join(stat_parts))

	var min_parts: Array = []
	for key in ["stability", "un", "security", "support"]:
		min_parts.append("%s %.0f" % [db.config["stats"][key]["short"], float(data["min_stats"].get(key, 0)) / runs])
	print("  средний минимум за партию: " + ", ".join(min_parts))
	print("  кризисов за партию: %.2f" % data["avg_crises"])
	var gate_parts: Array = []
	for gate in data["gates"]:
		gate_parts.append("%s %.0f%%" % [gate, 100.0 * float(data["gates"][gate]) / runs])
	print("  доля партий со шкалой не ниже 50: " + ", ".join(gate_parts))

	var trigger_parts: Array = []
	var codes: Array = data["triggers"].keys()
	codes.sort()
	for code in codes:
		trigger_parts.append("%s %.0f%%" % [code, 100.0 * float(data["triggers"][code]) / runs])
	print("  срабатывания триггеров: " + ", ".join(trigger_parts))
	print("")
