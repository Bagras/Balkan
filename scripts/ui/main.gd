extends Control

## Заглушка интерфейса. Ядро уже играбельно и проверяется headless-тестами;
## визуальная часть собирается отдельным этапом.

func _ready() -> void:
	var db := ContentDB.new()
	var err := db.load_all()
	if not err.is_empty():
		push_error(err)
		return
	print("Контент загружен: %d событий" % db.events.size())
