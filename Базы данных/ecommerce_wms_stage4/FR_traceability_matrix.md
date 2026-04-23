# Соответствие FR и SQL (этап 4)

Источник формулировок FR: «Задание 1 БД (1).md». Объекты с префиксом `stage4_`, чтобы не пересекаться с этапом 3.

| FR | Объект в `ecommerce_wms_stage4_dml.sql` |
|----|-------------------------------------------|
| R1.1 | сиды `order`, `order_item`; представление `stage4_vw_order_detail` |
| R1.2–R1.3 | сиды `incident`, `corrective_action` |
| R1.4 | запрос с `GROUP BY` в конце файла (CTE `x`) |
| R2.1–R2.2 | сиды `picking_operation`, `picking_task`, `picking_task_item`, `scan_event` |
| R2.3 | функция `stage4_order_timeline` |
| R3.1–R3.2 | сиды `picking_task`, `picking_task_item` |
| R3.3 | не выносили в отдельную функцию; по заданию достаточно общей логики на SQL |
| R4.1–R4.2, R4.4 | сиды `scan_event`, `weight_check`, `qc_check` |
| R4.3 | нет таблицы под фото в модели — не делали |
| R5.1 | сид `return_order`; представление `stage4_vw_incident_return` |
| R5.2–R5.3 | представление `stage4_vw_incident_return`; агрегирующий запрос с CTE |

Дополнительно по методичке: вызов функции из функции — `stage4_order_health` вызывает `stage4_order_line_count`.
