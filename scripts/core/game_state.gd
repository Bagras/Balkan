class_name GameState
extends RefCounted

## Всё изменяемое состояние партии. Не знает ни про UI, ни про правила —
## только хранит и даёт безопасный доступ к шкалам.

enum Phase { READY, CHOICE, CABINET, OVER }

var stats: Dictionary = {}
var turn: int = 0
var phase: Phase = Phase.READY

var seen_events: Dictionary = {}       ## код события -> сколько раз выпадало
var history: Array = []                ## [{turn, event, choice, title}]
var flags: Dictionary = {}             ## ветки С-1, блокировки концовок и т. п.

var scheduled: Array = []              ## [{trigger, turn, multiplier}] — отложенные триггеры
var trigger_weights: Dictionary = {}   ## код -> накопленный бонус к весу
var trigger_last_turn: Dictionary = {} ## код -> ход последнего срабатывания
var consecutive_triggers: int = 0

var action_cooldowns: Dictionary = {}  ## id действия -> ход, до которого недоступно
var acted_this_turn: bool = false

var crisis_stat: String = ""           ## шкала, обнулившаяся в прошлом ходу
var crisis_resolved_turn: int = -1
var low_stability_streak: int = 0

var defeat_reason: String = ""
var final_choice: int = 0              ## выбор в С-7

var _min: int = 0
var _max: int = 100
var _config: Dictionary = {}

var effect_multiplier: float = 1.0

var rng := RandomNumberGenerator.new()


func setup(config: Dictionary, seed_value: int = 0) -> void:
	_config = config
	_min = config["stat_min"]
	_max = config["stat_max"]
	effect_multiplier = float(config.get("effect_multiplier", 1.0))
	for key in config["stats"]:
		stats[key] = int(config["stats"][key]["start"])
	rng.seed = seed_value if seed_value != 0 else randi()


func get_stat(key: String) -> int:
	return int(stats.get(key, 0))


## Меняет шкалу с зажимом в границы. Возвращает фактическую дельту —
## она может отличаться от запрошенной, если шкала упёрлась в потолок или пол.
func add_stat(key: String, delta: int) -> int:
	if not stats.has(key):
		push_warning("неизвестная шкала: " + key)
		return 0
	var before: int = int(stats[key])
	stats[key] = clampi(before + delta, _min, _max)
	return int(stats[key]) - before


func set_flag(flag: String) -> void:
	flags[flag] = true


func has_flag(flag: String) -> bool:
	return flags.get(flag, false)


func mark_seen(code: String) -> void:
	seen_events[code] = int(seen_events.get(code, 0)) + 1


func times_seen(code: String) -> int:
	return int(seen_events.get(code, 0))


func is_seen(code: String) -> bool:
	return times_seen(code) > 0


## Лояльности общин, отсортированные по возрастанию: [[ключ, значение], ...]
func loyalties_sorted() -> Array:
	var pairs: Array = []
	for key in _config["stats"]:
		if _config["stats"][key].get("group", "") == "loyalty":
			pairs.append([key, get_stat(key)])
	pairs.sort_custom(func(a, b): return a[1] < b[1])
	return pairs


func loyalty_gap() -> int:
	var sorted_pairs := loyalties_sorted()
	if sorted_pairs.is_empty():
		return 0
	return int(sorted_pairs[-1][1]) - int(sorted_pairs[0][1])


func is_over() -> bool:
	return phase == Phase.OVER


func snapshot() -> Dictionary:
	return {
		"turn": turn,
		"stats": stats.duplicate(),
		"flags": flags.duplicate(),
		"defeat_reason": defeat_reason,
	}
