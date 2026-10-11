#!/usr/bin/env python3
"""Offline checks for l10n.py's recheck detector (run by CI's build)."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from l10n import contains_label  # noqa: E402

failures = 0


def check(cond, what):
    global failures
    if not cond:
        failures += 1
        print("FAIL:", what)


VOICE = "Voice Lab is off -- enable it in Settings > Voice."
FILES = "No embedding model: files are searched by their words. Download it in Settings > Files for search by meaning."
QUIT = "Quit it first (its menu bar icon › Quit)."
LAB = ("Voice Lab",)

# Translated, inflected, or with the key's other uses of the word kept.
check(contains_label("в разделе «Настройки › Модели»", "Модели", "Models", "in Settings › Models"), "ru path")
check(contains_label("Сначала включите в Настройках", "Настройки", "Settings", "Settings › Files"), "inflected")
check(contains_label("Voice Lab kapalı — Ayarlar > Ses’ten açın.", "Ses", "Voice", VOICE, LAB), "Voice Lab kept")
check(contains_label("Öffne „Modell“", "Modell", "Model", 'Open "Model" panel'), "translation contains English")
check(contains_label("Откройте Настройки > Voice Lab и Настройки > Голос.", "Голос", "Voice",
                     "Open Settings > Voice Lab and Settings > Voice.", LAB), "longer label is not this one")
check(contains_label("файлы ищутся. Скачайте в разделе «Настройки › Файлы»", "Файлы", "Files", FILES), "ordinary word")

# The English label left where the label goes, though a stem matches it.
check(not contains_label("Ustawienia › Models", "Modele", "Models", "save in Settings › Models"), "stem in English")
check(not contains_label("Ustawienia › models", "Modele", "Models", "save in Settings › Models"), "any case")
check(not contains_label("Voice Lab kapalı — Ayarlar > Voice", "Ses", "Voice", VOICE, LAB), "Voice left")
check(not contains_label("файлы ищутся. Скачайте в Настройки > Files", "Файлы", "Files", FILES), "Files left")
check(not contains_label("Otwórz „Models”, potem „Modele”.", "Modele", "Models", "Open “Models”, then “Models”."), "one of two")
check(not contains_label("Open Model panel", "Modell", "Model", 'Open "Model" panel'), "substring of translation")
check(not contains_label("Beende sie zuerst (Menüleistensymbol › Quit).", "Beenden", "Quit", QUIT), "menu item left")

if failures:
    sys.exit(f"{failures} check(s) failed")
print("l10n: all checks passed")
