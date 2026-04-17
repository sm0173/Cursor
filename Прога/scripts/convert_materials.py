# -*- coding: utf-8 -*-
"""
Конвертация материалов из «01_Оригиналы материалов» в текстовые выгрузки:
  - *.ipynb → .txt (Markdown через nbconvert)
  - *.pdf   → .txt (текст страниц через PyMuPDF)

Имя файла определяет папку назначения: «Seminar…» → «03_Материалы по питону»,
«Sem …» (семинары ИАД) → «02_Материалы по ИАДу».

Запуск из каталога `Прога/`: python scripts/convert_materials.py
Опции:  --pdf-only   только PDF
        --ipynb-only только ноутбуки
"""
from __future__ import annotations

import argparse
from pathlib import Path

# Корень зоны «Прога/» (скрипт лежит в scripts/)
ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "01_Оригиналы материалов"
DST_IAD = ROOT / "02_Материалы по ИАДу"
DST_PYTHON = ROOT / "03_Материалы по питону"


def output_dir_for_stem(stem: str) -> Path:
    """Seminar* → питон, Sem * → ИАД."""
    if stem.startswith("Seminar"):
        return DST_PYTHON
    return DST_IAD


def convert_ipynb() -> tuple[int, int]:
    from nbconvert import MarkdownExporter
    import nbformat

    exporter = MarkdownExporter()
    ok = fail = 0
    for ipynb in sorted(SRC.glob("*.ipynb")):
        try:
            nb = nbformat.read(ipynb, as_version=4)
            body, _ = exporter.from_notebook_node(nb)
            header = f"Источник: {ipynb.name}\n\n---\n\n"
            out_dir = output_dir_for_stem(ipynb.stem)
            out_dir.mkdir(parents=True, exist_ok=True)
            out_path = out_dir / f"{ipynb.stem}.txt"
            out_path.write_text(header + body, encoding="utf-8")
            print("OK ipynb:", ipynb.name)
            ok += 1
        except Exception as e:
            print("FAIL ipynb:", ipynb.name, e)
            fail += 1
    return ok, fail


def pdf_to_text(pdf_path: Path) -> str:
    import fitz  # PyMuPDF

    doc = fitz.open(pdf_path)
    try:
        parts: list[str] = []
        for i in range(len(doc)):
            text = doc[i].get_text("text")
            if text.strip():
                parts.append(f"--- страница {i + 1} ---\n\n{text.rstrip()}")
        return "\n\n".join(parts) if parts else ""
    finally:
        doc.close()


def convert_pdf() -> tuple[int, int]:
    ok = fail = 0
    pdfs = sorted(SRC.glob("*.pdf"))
    if not pdfs:
        print("PDF в папке не найдены.")
        return 0, 0
    for pdf in pdfs:
        try:
            body = pdf_to_text(pdf)
            header = (
                f"Источник: {pdf.name}\n"
                f"Формат: извлечение текста (PyMuPDF), без OCR.\n\n---\n\n"
            )
            out_dir = output_dir_for_stem(pdf.stem)
            out_dir.mkdir(parents=True, exist_ok=True)
            out_path = out_dir / f"{pdf.stem}.txt"
            out_path.write_text(header + body, encoding="utf-8")
            print("OK pdf:", pdf.name)
            ok += 1
        except Exception as e:
            print("FAIL pdf:", pdf.name, e)
            fail += 1
    return ok, fail


def main() -> None:
    parser = argparse.ArgumentParser(description="Конвертация ipynb и PDF в txt")
    parser.add_argument("--pdf-only", action="store_true", help="только PDF")
    parser.add_argument("--ipynb-only", action="store_true", help="только .ipynb")
    args = parser.parse_args()

    if not SRC.is_dir():
        print("Нет папки:", SRC)
        return

    DST_IAD.mkdir(parents=True, exist_ok=True)
    DST_PYTHON.mkdir(parents=True, exist_ok=True)

    total_ok = total_fail = 0
    if not args.pdf_only:
        o, f = convert_ipynb()
        total_ok += o
        total_fail += f
    if not args.ipynb_only:
        o, f = convert_pdf()
        total_ok += o
        total_fail += f

    print(f"\nИтого: {total_ok} успешно, {total_fail} с ошибкой")


if __name__ == "__main__":
    main()
