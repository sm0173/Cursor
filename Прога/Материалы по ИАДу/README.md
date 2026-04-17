# Материалы по ИАДу

Текстовые выгрузки из папки `Оригиналы материалов`:

- **`.ipynb`** → `.txt` (Markdown через nbconvert: заголовки, код, текст; картинки в ноутбуках — длинные base64).
- **`.pdf`** → `.txt` (текст страниц через PyMuPDF; сканы без слоя текста не распознаются — нужен отдельный OCR).

## Как обновить выгрузку

Из корня репозитория (или из папки `Прога`):

```bash
pip install -r "Прога/requirements-materials.txt"
python "Прога/convert_materials.py"
```

Только ноутбуки или только PDF:

```bash
python "Прога/convert_materials.py" --ipynb-only
python "Прога/convert_materials.py" --pdf-only
```

После добавления новых файлов в `Оригиналы материалов` снова запустите `convert_materials.py` — соответствующие `.txt` перезапишутся.
