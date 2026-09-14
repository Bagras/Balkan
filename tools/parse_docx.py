#!/usr/bin/env python3
"""Конвертер исходного .docx с ивентами в структурированный content/events.json.

Формат исходника (см. docs/DESIGN.md):
    № I. Заголовок            — рандомный ивент
    Т-1. Заголовок            — триггерный ивент
    С-1. Заголовок (ход 1)    — главносюжетный ивент
    Источник: ...             — только у триггерных
    <описание одним абзацем>
    ВЫБОРЫ:
    I. Текст выбора. {эффекты. Итоговый текст:} исход {постпримечание}
"""
import html
import json
import re
import sys
import zipfile

STAT_MAP = {
    "СТАБ": "stability", "ООН": "un", "ЛИЧ": "personal",
    "БЕЗ": "security", "ПОД": "support", "ВЛ": "influence",
    "Л-серб": "loyalty_serb", "Л-алб": "loyalty_alb", "Л-грек": "loyalty_greek",
    # Влияние соседей-патронов: события могут двигать его напрямую
    "Белград": "patron_belgrade", "Тирана": "patron_tirana", "Афины": "patron_athens",
}
ROMAN_VALUES = {"I": 1, "V": 5, "X": 10, "L": 50, "C": 100, "D": 500, "M": 1000}


def roman_to_int(text):
    """XXXI -> 31. Словаря на 30 позиций не хватает: пул событий растёт."""
    total, highest = 0, 0
    for char in reversed(text):
        value = ROMAN_VALUES[char]
        total += value if value >= highest else -value
        highest = max(highest, value)
    return total


CATEGORY_MAP = {
    "Межэтнические": "ethnic", "Экономические": "economic", "Политические": "political",
    "Внешнеполитические": "foreign", "Силовые": "security", "Силовой": "security",
}


# Эффекты, которые в исходнике записаны словами, а не шкалой: «Л-(их община)»,
# «по профильной шкале ветки» и т. п. Резолверы вычисляются в рантайме из
# текущего состояния партии — см. scripts/core/effects.gd.
#   loyalty_lowest                    — самая обделённая община (радикализация идёт оттуда)
#   loyalty_highest                   — община, держащая власть
#   loyalty_highest_excluding_lowest  — «другая община», не та, что подняла оружие
#   branch_stat                       — профильная шкала ветки С-6
#   donor_community                   — община донора, определяется влиянием патрона
DYNAMIC_PATCHES = {
    "XVII.1":  [{"resolver": "loyalty_lowest", "delta": -5}],
    "XX.1":    [{"resolver": "loyalty_highest", "delta": -3}],
    "XXIX.1":  [{"resolver": "loyalty_lowest", "delta": -4}],
    "XXIX.2":  [{"resolver": "loyalty_highest_excluding_lowest", "delta": -2}],
    "Т-7.3":   [{"resolver": "loyalty_lowest", "delta": -3}],
    "Т-8.2":   [{"resolver": "donor_community", "delta": 2}],
    "С-6.1":   [{"resolver": "branch_stat", "delta": 5}],
}

# Условия доступности выборов, заданные в исходнике прозой.
REQUIREMENT_PATCHES = {
    "С-4.1": {"type": "stat_above", "stat": "influence", "value": 55},
    "С-7.1": {"type": "best_ending"},
    "С-7.2": {"type": "mid_ending"},
    "С-7.3": {"type": "always"},
}


def source_to_lines(path):
    """Читает .docx или простой .txt в том же формате — формат авторский, один."""
    if path.lower().endswith(".docx"):
        with zipfile.ZipFile(path) as z:
            xml = z.read("word/document.xml").decode("utf-8")
        xml = re.sub(r"</w:p>", "\n", xml)
        xml = re.sub(r"<w:tab/>", "\t", xml)
        xml = re.sub(r"<[^>]+>", "", xml)
        text = html.unescape(xml)
    else:
        text = open(path, encoding="utf-8").read()
    # нормализуем типографику, чтобы дальше не ловить оба варианта минуса
    text = text.replace("−", "-").replace("–", "-").replace("‑", "-")
    return [ln.strip() for ln in text.split("\n")]


def parse_effects(block):
    """'+3 ООН, -2 БЕЗ' -> ({'un': 3, 'security': -2}, [нераспознанные куски])."""
    effects, unresolved = {}, []
    for part in re.split(r"[,;]", block):
        part = part.strip().rstrip(".")
        if not part:
            continue
        m = re.match(r"^([+-])\s*(\d+)\s+(.+)$", part)
        if not m:
            unresolved.append(part)
            continue
        sign, value, stat_raw = m.group(1), int(m.group(2)), m.group(3).strip()
        delta = value if sign == "+" else -value
        key = STAT_MAP.get(stat_raw)
        if key is None:
            # 'ПОД(север)', 'Л-серб или Л-грек (...)', 'по профильной шкале ветки'
            base = re.match(r"^(Л-серб|Л-алб|Л-грек|СТАБ|ООН|ЛИЧ|БЕЗ|ПОД|ВЛ|Белград|Тирана|Афины)\b", stat_raw)
            if base and "или" not in stat_raw:
                key = STAT_MAP[base.group(1)]
                effects[key] = effects.get(key, 0) + delta
                unresolved.append(f"{part} [уточнение: {stat_raw}]")
            else:
                unresolved.append(part)
            continue
        effects[key] = effects.get(key, 0) + delta
    return effects, unresolved


# Служебные строки под заголовком события: это пометки автора, а не текст,
# который видит игрок. Сохраняются отдельным полем, в описание не попадают.
SERVICE_PREFIXES = ("Источник:", "Ветка определяется")

BRANCH_FLAGS = {
    "Администратор порядка": "branch_order",
    "Технократ": "branch_technocrat",
    "Переговорщик": "branch_negotiator",
}


def _targets(text):
    """Все коды триггеров/сюжетных событий, упомянутые в куске заметки."""
    return re.findall(r"(?:[ТС]-\d+|Ц-[А-Я]\d+)", text)


def parse_note(note):
    """Заметку прозой («Через 6-9 ходов — Т-1») превращает в исполняемые хуки.

    Типы хуков:
      schedule  — взвести отложенный триггер через min..max ходов
      weight    — поднять вес триггера в очереди
      flag      — выставить флаг ветки/бонуса для сюжетных событий и концовок
      guarantee — гарантированно выдать один из триггеров, если он ещё не выпадал
    """
    if not note:
        return []
    hooks = []
    for clause in re.split(r"[;]", note):
        clause = clause.strip()
        if not clause:
            continue
        targets = _targets(clause)

        branch = re.search(r"«([^»]+)»", clause)
        if branch and "ветк" in clause:
            hooks.append({"type": "flag", "flag": BRANCH_FLAGS.get(branch.group(1), "branch_unknown")})
            continue
        if "Сильный бонус" in clause:
            hooks.append({"type": "flag", "flag": "crisis_handled_well"}); continue
        if "Штраф к" in clause:
            hooks.append({"type": "flag", "flag": "crisis_handled_badly"})
        if "блокирует лучшие концовки" in clause:
            hooks.append({"type": "flag", "flag": "best_ending_blocked"}); continue
        if "Ключевое условие лучших концовок" in clause:
            hooks.append({"type": "flag", "flag": "best_ending_enabled"}); continue
        if clause.startswith("Гарантирует"):
            hooks.append({"type": "guarantee", "targets": targets, "only_if_unseen": True}); continue
        if clause.lower().startswith("повышает вероятность"):
            hooks.append({"type": "weight", "targets": targets, "bonus": 2}); continue

        # отложенное срабатывание: окно ходов в любой из формулировок
        window = re.search(r"через\s+(\d+)\s*[-–—]\s*(\d+)\s+ход", clause, re.IGNORECASE)
        plusminus = re.search(r"через\s*±\s*(\d+)\s+ход", clause, re.IGNORECASE)
        if window:
            lo, hi = int(window.group(1)), int(window.group(2))
        elif plusminus:
            n = int(plusminus.group(1)); lo, hi = max(1, n - 2), n + 2
        else:
            lo = hi = None

        condition, chance = None, None
        if "при ЛИЧ выше порога" in clause:
            condition = {"type": "stat_above", "stat": "personal", "value": 40}
            lo, hi = (lo or 1), (hi or 3)
        elif "при утечке" in clause:
            chance = 0.5
            lo, hi = (lo or 3), (hi or 6)
        else:
            low = re.search(r"Если\s+(Л-серб|Л-алб|Л-грек)\s+низкая", clause)
            if low:
                condition = {"type": "stat_below", "stat": STAT_MAP[low.group(1)], "value": 35}

        if targets and lo is not None:
            hook = {"type": "schedule", "targets": targets, "min": lo, "max": hi}
            if condition:
                hook["condition"] = condition
            if chance:
                hook["chance"] = chance
            if "удвоенным эффектом" in clause:
                hook["multiplier"] = 2
            hooks.append(hook)
        elif targets:
            hooks.append({"type": "weight", "targets": targets, "bonus": 2})
    return hooks


def parse_choice(line, event_code):
    m = re.match(r"^([IVX]+)\.\s+(.*)$", line)
    if not m:
        return None
    index, rest = roman_to_int(m.group(1)), m.group(2)

    note = None
    tail = re.search(r"\{([^{}]*)\}\s*$", rest)
    brace_blocks = re.findall(r"\{([^{}]*)\}", rest)
    if tail and "Итоговый текст" not in tail.group(1) and len(brace_blocks) > 1:
        note = tail.group(1).strip()
        rest = rest[: tail.start()].strip()

    split = re.search(r"\{(.*?)\.?\s*Итоговый текст:\s*\}", rest)
    if split:
        head = rest[: split.start()].strip()
        raw_effects = split.group(1).strip()
        outcome = rest[split.end():].strip()
    else:  # С-7: условия доступности без численных эффектов
        only = re.search(r"\{(.*?)\}", rest)
        head = rest[: only.start()].strip() if only else rest
        raw_effects = only.group(1).strip() if only else ""
        outcome = rest[only.end():].strip() if only else ""

    requirement = None
    req = re.match(r"^((?:Требует|Доступно)[^.]*\.?)\s*(.*)$", raw_effects)
    if req:
        requirement, raw_effects = req.group(1).strip(), req.group(2).strip()

    effects, unresolved = parse_effects(raw_effects)
    key = f"{event_code}.{index}"
    dynamic = DYNAMIC_PATCHES.get(key, [])
    if dynamic:
        unresolved = []  # разрешено таблицей DYNAMIC_PATCHES
    return {
        "dynamic_effects": dynamic,
        "hooks": parse_note(note),
        "condition": REQUIREMENT_PATCHES.get(key),
        "index": index,
        "text": head.rstrip("."),
        "effects": effects,
        "outcome": outcome,
        "requirement": requirement,
        "note": note,
        "raw_effects": raw_effects,
        "unresolved": unresolved,
    }


def parse(lines):
    events, current, category, kind = [], None, None, None
    expecting_choices = False

    for line in lines:
        if not line:
            continue
        if line == "РАНДОМНЫЕ ИВЕНТЫ":
            kind = "random"; continue
        if line == "ТРИГГЕРНЫЕ ИВЕНТЫ":
            kind = "trigger"; continue
        if line == "ГЛАВНОСЮЖЕТНЫЕ ИВЕНТЫ":
            kind = "story"; continue
        if line == "ЦЕПОЧКИ":
            kind = "chain"; continue
        if line.startswith("Черновая рамка концовок"):
            break

        cat = re.match(r"^(Межэтнические|Экономические|Политические|Внешнеполитические|Силовые|Силовой)\s*\(\d+\)$", line)
        if cat:
            category = CATEGORY_MAP[cat.group(1)]; continue

        head = (re.match(r"^№\s+([IVXLCDM]+)\.\s+(.+)$", line)
                or re.match(r"^(Т-\d+)\.\s+(.+)$", line)
                or re.match(r"^(С-\d+)\.\s+(.+)$", line)
                or re.match(r"^(Ц-[А-Я]\d+)\.\s+(.+)$", line))
        if head and kind:
            ident, title = head.group(1), head.group(2).strip()
            # Вид события определяет его код, а не порядок заголовков в файле:
            # иначе стартовое событие после секции «ЦЕПОЧКИ» молча становится
            # её шагом и перестаёт выпадать случайно.
            if ident.startswith("Ц-"):
                event_kind = "chain"
            elif ident.startswith("Т-"):
                event_kind = "trigger"
            elif ident.startswith("С-"):
                event_kind = "story"
            else:
                event_kind = "random"
            turn_window = None
            tw = re.search(r"\(ход\s+([\d–\-—]+)\)\s*$", title)
            if tw:
                nums = [int(n) for n in re.findall(r"\d+", tw.group(1))]
                turn_window = [nums[0], nums[-1]]
                title = title[: tw.start()].strip()
            current = {
                "id": ident if event_kind != "random" else f"R-{roman_to_int(ident):02d}",
                "code": ident, "kind": event_kind, "category": category,
                "title": title, "turn_window": turn_window,
                "source": None, "design_note": None, "description": "", "choices": [],
            }
            events.append(current)
            expecting_choices = False
            continue

        if current is None:
            continue
        if line.startswith("Источник:"):
            current["source"] = line[len("Источник:"):].strip(); continue
        if line.startswith(SERVICE_PREFIXES):
            current["design_note"] = line; continue
        if line == "ВЫБОРЫ:":
            expecting_choices = True; continue
        if expecting_choices:
            choice = parse_choice(line, current["code"])
            if choice:
                current["choices"].append(choice)
            continue
        if not current["description"]:
            current["description"] = line
        else:
            current["description"] += "\n" + line
    return events


def main():
    src, dst = sys.argv[1], sys.argv[2]
    events = parse(source_to_lines(src))
    with open(dst, "w", encoding="utf-8") as f:
        json.dump({"events": events}, f, ensure_ascii=False, indent=2)

    by_kind = {}
    for e in events:
        by_kind[e["kind"]] = by_kind.get(e["kind"], 0) + 1
    choices = sum(len(e["choices"]) for e in events)
    print(f"событий: {len(events)} {by_kind}, выборов: {choices}")
    for e in events:
        if len(e["choices"]) != 3:
            print(f"  !! {e['code']} {e['title']}: выборов {len(e['choices'])}")
        if not e["description"]:
            print(f"  !! {e['code']} {e['title']}: пустое описание")
        if "\n" in e["description"]:
            print(f"  !! {e['code']} {e['title']}: описание из нескольких абзацев — "
                  f"проверь, не попала ли туда служебная строка")
        for c in e["choices"]:
            for u in c["unresolved"]:
                print(f"  ?  {e['code']}.{c['index']}: {u}")


if __name__ == "__main__":
    main()
