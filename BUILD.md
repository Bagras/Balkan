# Сборка

Готовые пресеты лежат в `export_presets.cfg`: Linux x86_64 и Windows x86_64,
оба с упакованным внутрь контентом — на выходе **один файл**, которому не нужен
ни Godot, ни отдельная папка с данными.

## Разово: шаблоны экспорта

Godot не умеет собирать без шаблонов, а в поставку редактора они не входят.
Editor → Управление шаблонами экспорта → Загрузить и установить.

Либо вручную, если качать из редактора неудобно:

```bash
curl -L -o templates.tpz \
  https://github.com/godotengine/godot/releases/download/4.3-stable/Godot_v4.3-stable_export_templates.tpz
mkdir -p ~/.local/share/godot/export_templates/4.3.stable
unzip -j templates.tpz "templates/linux_release.x86_64" \
  "templates/windows_release_x86_64.exe" "templates/version.txt" \
  -d ~/.local/share/godot/export_templates/4.3.stable/
```

Архив весит около гигабайта, распакованные два шаблона — примерно 150 МБ,
архив после распаковки можно удалить.

## Сборка

```bash
godot --headless --path . --export-release "Linux"   build/linux/balkan-protectorate.x86_64
godot --headless --path . --export-release "Windows" build/windows/balkan-protectorate.exe
```

Размер около 66 МБ под Linux и 85 МБ под Windows — это вес самого движка,
контент игры занимает меньше мегабайта.

## Проверка, что сборка не пустая

Экспорт Godot по умолчанию упаковывает ресурсы, а весь контент игры — обычные
`.json`. Поэтому после сборки стоит убедиться, что он внутри:

```bash
grep -qa "Стефана Йовановича" build/linux/balkan-protectorate.x86_64 && echo "контент на месте"
```

## Что в сборку не попадает

`tools/`, `tests/`, `docs/` и исходные текстовые файлы событий исключены
пресетом: игроку они не нужны, а `events_extra.txt` — это ещё и спойлер
на весь контент игры.

Сборки в репозиторий не коммитятся (`.gitignore`).
