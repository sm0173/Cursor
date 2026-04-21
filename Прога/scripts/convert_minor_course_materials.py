# -*- coding: utf-8 -*-
"""
Конвертация материалов майнора: PDF, DOCX → Markdown в папке «Майнор - конвертированное».
SQL из корня «Майнор» копируются как есть.

Запуск из корня репозитория:

  python Прога/scripts/convert_minor_course_materials.py
"""
from __future__ import annotations

from pathlib import Path

from course_materials_convert import convert_materials_folder

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "Майнор"
DST = ROOT / "Майнор - конвертированное"


def main() -> None:
    convert_materials_folder(
        SRC,
        DST,
        readme_title="Майнор — конвертированные материалы",
        src_folder_name_for_text="Майнор",
        run_command_hint="python Прога/scripts/convert_minor_course_materials.py",
    )


if __name__ == "__main__":
    main()
