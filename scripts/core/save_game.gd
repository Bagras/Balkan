class_name SaveGame
extends RefCounted

## Сохранение и загрузка партии. Пишет один файл в user:// — автосейв после
## каждого хода. Ручных слотов нет намеренно: игра про необратимые решения,
## возможность переиграть неудачный ход ломает весь смысл.

const PATH := "user://save.json"
const VERSION := 1


static func has_save() -> bool:
	return FileAccess.file_exists(PATH)


static func clear() -> void:
	if FileAccess.file_exists(PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(PATH))


## Возвращает пустую строку при успехе, иначе текст ошибки.
static func save(game: Game) -> String:
	var file := FileAccess.open(PATH, FileAccess.WRITE)
	if file == null:
		return "не удалось открыть файл сохранения на запись"
	file.store_string(JSON.stringify(to_dict(game), "  "))
	file.close()
	return ""


static func load_into(game: Game) -> String:
	if not has_save():
		return "сохранения нет"
	var text := FileAccess.get_file_as_string(PATH)
	var parsed = JSON.parse_string(text)
	if parsed == null or not (parsed is Dictionary):
		return "файл сохранения повреждён"
	if int(parsed.get("version", 0)) != VERSION:
		return "сохранение от другой версии игры"
	return from_dict(game, parsed)


static func to_dict(game: Game) -> Dictionary:
	var state := game.state
	return {
		"version": VERSION,
		"turn": state.turn,
		"phase": int(state.phase),
		"stats": state.stats,
		"seen_events": state.seen_events,
		"history": state.history,
		"flags": state.flags,
		"scheduled": state.scheduled,
		"trigger_weights": state.trigger_weights,
		"trigger_last_turn": state.trigger_last_turn,
		"consecutive_triggers": state.consecutive_triggers,
		"action_cooldowns": state.action_cooldowns,
		"acted_this_turn": state.acted_this_turn,
		"crisis_stat": state.crisis_stat,
		"crisis_resolved_turn": state.crisis_resolved_turn,
		"low_stability_streak": state.low_stability_streak,
		"defeat_reason": state.defeat_reason,
		"final_choice": state.final_choice,
		# Зерно и позиция генератора: без них продолженная партия пошла бы
		# по другой случайной ветке, чем сохранённая.
		"rng_seed": state.rng.seed,
		"rng_state": state.rng.state,
		"current_event": String(game.current_event.get("code", game.current_event.get("id", ""))),
		"current_scale": game.current_scale,
		"current_source": game.current_source,
	}


static func from_dict(game: Game, data: Dictionary) -> String:
	game.start(1)
	var state := game.state

	state.turn = int(data.get("turn", 0))
	state.phase = int(data.get("phase", GameState.Phase.READY)) as GameState.Phase
	state.consecutive_triggers = int(data.get("consecutive_triggers", 0))
	state.acted_this_turn = bool(data.get("acted_this_turn", false))
	state.crisis_stat = String(data.get("crisis_stat", ""))
	state.crisis_resolved_turn = int(data.get("crisis_resolved_turn", -1))
	state.low_stability_streak = int(data.get("low_stability_streak", 0))
	state.defeat_reason = String(data.get("defeat_reason", ""))
	state.final_choice = int(data.get("final_choice", 0))

	# JSON возвращает числа как float — всё числовое приводим явно
	for key in data.get("stats", {}):
		state.stats[key] = int(data["stats"][key])
	state.seen_events = {}
	for key in data.get("seen_events", {}):
		state.seen_events[key] = int(data["seen_events"][key])
	state.trigger_weights = {}
	for key in data.get("trigger_weights", {}):
		state.trigger_weights[key] = int(data["trigger_weights"][key])
	state.trigger_last_turn = {}
	for key in data.get("trigger_last_turn", {}):
		state.trigger_last_turn[key] = int(data["trigger_last_turn"][key])
	state.action_cooldowns = {}
	for key in data.get("action_cooldowns", {}):
		state.action_cooldowns[key] = int(data["action_cooldowns"][key])

	state.flags = {}
	for key in data.get("flags", {}):
		state.flags[key] = bool(data["flags"][key])

	state.scheduled = []
	for entry in data.get("scheduled", []):
		state.scheduled.append({
			"trigger": String(entry["trigger"]),
			"turn": int(entry["turn"]),
			"multiplier": int(entry.get("multiplier", 1)),
		})

	state.history = []
	for entry in data.get("history", []):
		state.history.append({
			"turn": int(entry["turn"]),
			"event": String(entry["event"]),
			"title": String(entry["title"]),
			"choice": int(entry["choice"]),
			"choice_text": String(entry["choice_text"]),
		})

	state.rng.seed = int(data.get("rng_seed", 0))
	state.rng.state = int(data.get("rng_state", 0))

	var code := String(data.get("current_event", ""))
	game.current_event = game.db.get_event(code) if not code.is_empty() else {}
	game.current_scale = float(data.get("current_scale", 1.0))
	game.current_source = String(data.get("current_source", ""))

	if state.phase == GameState.Phase.CHOICE and game.current_event.is_empty():
		return "сохранение ссылается на неизвестное событие: " + code
	return ""
