# -*- coding: utf-8 -*-
"""
Конвертация материалов курса «Базы данных» (PDF, DOCX) в Markdown.
Запуск из корня репозитория:

  python Прога/scripts/convert_bd_course_materials.py
"""
from __future__ import annotations

from pathlib import Path

from course_materials_convert import convert_materials_folder

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "Базы данных"
DST = ROOT / "Базы данных - конвертированное"


def main() -> None:
    convert_materials_folder(
        SRC,
        DST,
        readme_title="Базы данных — конвертированные материалы",
        src_folder_name_for_text="Базы данных",
        run_command_hint="python Прога/scripts/convert_bd_course_materials.py",
    )


if __name__ == "__main__":
    main()
