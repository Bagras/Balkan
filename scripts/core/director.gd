class_name Director
extends RefCounted

## Решает, какое событие придёт следующим ходом, и обслуживает патронов
## и отложенные триггеры. Приоритет: кризис > сюжет > триггер > случайное.

var db: ContentDB


func _init(content_db: ContentDB) -> void:
	db = content_db


## Дрейф влияния патронов. Сосед включается, когда его община уходит в любую
## крайность: при высокой лояльности — чтобы закрепить успех, при низкой —
## чтобы «защитить своих». Спокойная община патрона усыпляет.
func tick_patrons(state: GameState) -> void:
	var rules: Dictionary = db.config["patron_drift"]
	for patron_key in db.config["patrons"]:
		var community: String = String(db.config["patrons"][patron_key]["community"])
		var deviation: int = absi(state.get_stat(community) - 50)
		var drift := float(deviation - int(rules["neutral_band"])) / float(rules["divisor"])
		var step := clampi(int(round(drift)), int(rules["min"]), int(rules["max"]))
		state.add_stat(patron_key, step)


## Сила патронского события растёт с влиянием патрона: степень влияния
## определяет, насколько сильным будет эффект (потолок — полуторный).
func patron_scale(state: GameState, patron_key: String) -> float:
	var threshold: float = float(db.config["patron_trigger"]["influence_min"])
	return clampf(float(state.get_stat(patron_key)) / threshold, 1.0, 1.6)


## Возвращает {event, scale, source}. source — для отладки и симулятора.
func select_event(state: GameState) -> Dictionary:
	var crisis := _select_crisis(state)
	if not crisis.is_empty():
		return {"event": crisis, "scale": 1.0, "source": "crisis"}

	var story := _select_story(state)
	if not story.is_empty():
		return {"event": story, "scale": 1.0, "source": "story"}

	var rules: Dictionary = db.config["trigger_rules"]
	if state.consecutive_triggers < int(rules["max_consecutive"]):
		var triggered := _select_trigger(state)
		if not triggered.is_empty():
			return triggered

	var random_event := _select_random(state)
	if not random_event.is_empty():
		return {"event": random_event, "scale": 1.0, "source": "random"}

	return {}


func _select_crisis(state: GameState) -> Dictionary:
	if state.crisis_stat.is_empty():
		return {}
	for crisis in db.crises:
		if String(crisis["stat"]) == state.crisis_stat:
			return crisis
	return {}


## Сюжетные события жёстко привязаны к ходам. Если окно уже наступило,
## событие выпадает при первой возможности — пропустить его нельзя.
func _select_story(state: GameState) -> Dictionary:
	var best: Dictionary = {}
	var best_start := 9999
	for event in db.events:
		if event["kind"] != "story" or state.is_seen(String(event["code"])):
			continue
		var window = event.get("turn_window")
		if window == null:
			continue
		var start := int(window[0])
		if state.turn >= start and start < best_start:
			best = event
			best_start = start
	return best


func _select_trigger(state: GameState) -> Dictionary:
	var rules: Dictionary = db.config["trigger_rules"]
	var cooldown := int(rules["same_trigger_cooldown"])

	# 1. Отложенные триггеры: срок подошёл — выдаём, это обещание, данное игроку.
	var due: Array = []
	for entry in state.scheduled:
		if int(entry["turn"]) <= state.turn and _cooled_down(state, String(entry["trigger"]), cooldown):
			due.append(entry)
	if not due.is_empty():
		var chosen: Dictionary = due[0]
		state.scheduled.erase(chosen)
		var event := db.get_event(String(chosen["trigger"]))
		if not event.is_empty():
			return {
				"event": event,
				"scale": float(chosen.get("multiplier", 1)),
				"source": "scheduled",
			}

	# 2. Патронские события: влияние выше порога, знак задаёт лояльность общины.
	var patron := _select_patron(state)
	if not patron.is_empty():
		return patron

	# 3. Пороговые триггеры: взвешенный выбор среди тех, чьё условие выполнено.
	var eligible: Array = []
	var weights: Array = []
	for code in db.config["trigger_conditions"]:
		if not _cooled_down(state, String(code), cooldown):
			continue
		if not Effects.check(state, db.config["trigger_conditions"][code]):
			continue
		var event := db.get_event(String(code))
		if event.is_empty():
			continue
		eligible.append(event)
		weights.append(1 + int(state.trigger_weights.get(code, 0)))
	if eligible.is_empty():
		return {}
	var picked: Dictionary = _weighted_pick(state, eligible, weights)
	return {"event": picked, "scale": 1.0, "source": "threshold"}


func _select_patron(state: GameState) -> Dictionary:
	var thresholds: Dictionary = db.config["patron_trigger"]
	var cooldown := int(db.config["trigger_rules"]["same_trigger_cooldown"])
	var candidates: Array = []

	for event in db.patron_events:
		var patron_key: String = String(event["patron"])
		if state.get_stat(patron_key) < int(thresholds["influence_min"]):
			continue
		if not _cooled_down(state, String(event["id"]), cooldown):
			continue
		var community: String = String(db.config["patrons"][patron_key]["community"])
		var loyalty := state.get_stat(community)
		var is_gift: bool = String(event["polarity"]) == "gift"
		if is_gift and loyalty >= int(thresholds["loyalty_high"]):
			candidates.append(event)
		elif not is_gift and loyalty <= int(thresholds["loyalty_low"]):
			candidates.append(event)

	if candidates.is_empty():
		return {}
	var picked: Dictionary = candidates[state.rng.randi_range(0, candidates.size() - 1)]
	return {
		"event": picked,
		"scale": patron_scale(state, String(picked["patron"])),
		"source": "patron",
	}


func _select_random(state: GameState) -> Dictionary:
	var pool: Array = []
	for event in db.events:
		if event["kind"] == "random" and not state.is_seen(String(event["code"])):
			pool.append(event)
	if pool.is_empty():
		return {}
	return pool[state.rng.randi_range(0, pool.size() - 1)]


func _cooled_down(state: GameState, code: String, cooldown: int) -> bool:
	if not state.trigger_last_turn.has(code):
		return true
	return state.turn - int(state.trigger_last_turn[code]) >= cooldown


func _weighted_pick(state: GameState, items: Array, weights: Array) -> Dictionary:
	var total := 0
	for w in weights:
		total += int(w)
	var roll := state.rng.randi_range(1, maxi(total, 1))
	var running := 0
	for i in items.size():
		running += int(weights[i])
		if roll <= running:
			return items[i]
	return items[-1]


## Исполняет хуки выбора: взводит отложенные триггеры, поднимает веса,
## выставляет флаги веток.
func apply_hooks(state: GameState, choice: Dictionary) -> void:
	for hook in choice.get("hooks", []):
		match String(hook["type"]):
			"flag":
				state.set_flag(String(hook["flag"]))
			"weight":
				for code in hook["targets"]:
					state.trigger_weights[code] = int(state.trigger_weights.get(code, 0)) + int(hook["bonus"])
			"schedule":
				_schedule(state, hook)
			"guarantee":
				for code in hook["targets"]:
					if not state.is_seen(String(code)):
						state.scheduled.append({
							"trigger": String(code),
							"turn": state.turn + 1,
							"multiplier": 1,
						})
						break
			_:
				push_warning("неизвестный хук: " + String(hook["type"]))


func _schedule(state: GameState, hook: Dictionary) -> void:
	if hook.has("condition") and not Effects.check(state, hook["condition"]):
		return
	if hook.has("chance") and state.rng.randf() > float(hook["chance"]):
		return
	var targets: Array = hook["targets"]
	if targets.is_empty():
		return
	var code: String = String(targets[state.rng.randi_range(0, targets.size() - 1)])
	var delay := state.rng.randi_range(int(hook["min"]), int(hook["max"]))
	state.scheduled.append({
		"trigger": code,
		"turn": state.turn + delay,
		"multiplier": int(hook.get("multiplier", 1)),
	})
