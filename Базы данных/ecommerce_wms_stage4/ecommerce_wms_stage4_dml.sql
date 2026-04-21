-- этап 4 нашей курсовой (ecommerce_wms)
-- перед запуском: залить базу из бэкапа задания 3 как мы делали в отчёте
-- потом в pgAdmin просто открыть файл и выполнить целиком (кнопка execute)
-- важно: таблица order в кавычках, иначе postgres ругается — мы так и оставили

SET client_encoding = 'UTF8';

-- VIEW-шки (по методичке нужны представления, мы накидали 4 штуки для отчётов)
-- фильтр stage4-ext-% чтобы не мешать чужим данным если в базе что-то ещё есть

CREATE OR REPLACE VIEW ecommerce_wms.stage4_vw_order_detail AS
SELECT
    o.order_id,
    o.external_order_no,
    o.order_datetime,
    o.order_status,
    o.expected_total_weight,
    oi.order_item_id,
    oi.ordered_qty,
    oi.collected_qty,
    p.sku_code,
    p.product_name,
    p.unit_weight
FROM ecommerce_wms."order" o
JOIN ecommerce_wms.order_item oi ON oi.order_id = o.order_id
JOIN ecommerce_wms.product p ON p.product_id = oi.product_id
WHERE o.external_order_no LIKE 'stage4-ext-%';  -- наши тестовые заказы

-- отбор: много join-ов, scan через left join потому что не у каждой операции он есть в тесте
CREATE OR REPLACE VIEW ecommerce_wms.stage4_vw_picking_ops AS
SELECT
    o.external_order_no,
    pt.task_id,
    pt.task_status,
    pt.created_at AS task_created_at,
    pt.started_at,
    pt.completed_at,
    pti.task_item_id,
    pti.planned_qty,
    pti.picked_qty AS task_item_picked_qty,
    po.operation_id,
    po.operation_datetime,
    po.picked_qty AS operation_picked_qty,
    po.operation_result,
    sl.location_code,
    sz.zone_name,
    w.warehouse_name,
    e.full_name AS picker_name,
    se.scan_id,
    se.barcode_value AS scan_barcode,
    se.is_successful AS scan_ok,
    se.scan_datetime
FROM ecommerce_wms."order" o
JOIN ecommerce_wms.picking_task pt ON pt.order_id = o.order_id
JOIN ecommerce_wms.employee e ON e.employee_id = pt.employee_id
JOIN ecommerce_wms.picking_task_item pti ON pti.task_id = pt.task_id
JOIN ecommerce_wms.storage_location sl ON sl.location_id = pti.location_id
JOIN ecommerce_wms.storage_zone sz ON sz.zone_id = sl.zone_id
JOIN ecommerce_wms.warehouse w ON w.warehouse_id = sz.warehouse_id
LEFT JOIN ecommerce_wms.picking_operation po ON po.task_item_id = pti.task_item_id
LEFT JOIN ecommerce_wms.scan_event se ON se.operation_id = po.operation_id
WHERE o.external_order_no LIKE 'stage4-ext-%';

CREATE OR REPLACE VIEW ecommerce_wms.stage4_vw_quality_checks AS
SELECT
    o.external_order_no,
    o.order_status,
    wc.weight_check_id,
    wc.expected_weight,
    wc.actual_weight,
    wc.deviation_percent,
    wc.check_status AS weight_status,
    wc.check_datetime AS weight_checked_at,
    qc.qc_check_id,
    qc.qc_result,
    qc.qc_datetime AS qc_at,
    qc.comment AS qc_comment
FROM ecommerce_wms."order" o
LEFT JOIN ecommerce_wms.weight_check wc ON wc.order_id = o.order_id
LEFT JOIN ecommerce_wms.qc_check qc ON qc.order_id = o.order_id
WHERE o.external_order_no LIKE 'stage4-ext-%';

-- возвраты+инциденты в одну кучу (для отчёта удобно хоть строки дублируются иногда)
CREATE OR REPLACE VIEW ecommerce_wms.stage4_vw_incidents_returns AS
SELECT
    o.external_order_no,
    i.incident_id,
    i.incident_type,
    i.detected_stage,
    i.incident_datetime,
    i.status AS incident_status,
    i.description AS incident_description,
    ca.action_id,
    ca.action_type,
    ca.action_datetime,
    ca.comment AS corrective_comment,
    ro.return_id,
    ro.return_reason,
    ro.return_datetime,
    ro.return_status
FROM ecommerce_wms."order" o
LEFT JOIN ecommerce_wms.incident i ON i.order_id = o.order_id
LEFT JOIN ecommerce_wms.corrective_action ca ON ca.incident_id = i.incident_id
LEFT JOIN ecommerce_wms.return_order ro ON ro.order_id = o.order_id
WHERE o.external_order_no LIKE 'stage4-ext-%';

-- функции
-- маленькая функция — считает строки в заказе (для другой функции пригодилась)

CREATE OR REPLACE FUNCTION ecommerce_wms.stage4_order_line_count(p_order_id bigint)
RETURNS bigint
LANGUAGE sql
AS $f$
    SELECT count(*)::bigint
    FROM ecommerce_wms.order_item oi
    WHERE oi.order_id = p_order_id;
$f$;

-- эта вызывает ту что выше (в задании типа надо показать вызов функции из функции)
CREATE OR REPLACE FUNCTION ecommerce_wms.stage4_order_health(p_order_id bigint)
RETURNS text
LANGUAGE plpgsql
AS $f$
DECLARE
    c bigint;
BEGIN
    c := ecommerce_wms.stage4_order_line_count(p_order_id);
    IF EXISTS (
        SELECT 1
        FROM ecommerce_wms.incident i
        WHERE i.order_id = p_order_id
          AND i.status = ANY (ARRAY['open'::ecommerce_wms.incident_status_type, 'in_progress'::ecommerce_wms.incident_status_type])
    ) THEN
        RETURN format('заказ %s позиций %s — есть открытый инцидент', p_order_id, c);
    END IF;
    RETURN format('заказ %s позиций %s — без открытых инцидентов', p_order_id, c);
END;
$f$;

-- таймлайн заказа — много union all, внутри with как на паре разбирали
CREATE OR REPLACE FUNCTION ecommerce_wms.stage4_order_timeline(p_order_id bigint)
RETURNS TABLE (
    event_ts timestamp without time zone,
    event_kind text,
    event_detail text
)
LANGUAGE sql
AS $f$
    SELECT *
    FROM (
        WITH ev AS (
            SELECT
                o.order_datetime AS event_ts,
                'order'::text AS event_kind,
                format('status=%s ext=%s', o.order_status, o.external_order_no) AS event_detail
            FROM ecommerce_wms."order" o
            WHERE o.order_id = p_order_id
            UNION ALL
            SELECT pt.created_at, 'picking_task', format('task=%s status=%s', pt.task_id, pt.task_status)
            FROM ecommerce_wms.picking_task pt
            WHERE pt.order_id = p_order_id
            UNION ALL
            SELECT po.operation_datetime, 'picking_operation', format('op=%s result=%s qty=%s', po.operation_id, po.operation_result, po.picked_qty)
            FROM ecommerce_wms.picking_operation po
            JOIN ecommerce_wms.picking_task_item pti ON pti.task_item_id = po.task_item_id
            JOIN ecommerce_wms.picking_task pt ON pt.task_id = pti.task_id
            WHERE pt.order_id = p_order_id
            UNION ALL
            SELECT se.scan_datetime, 'scan', format('scan=%s ok=%s code=%s', se.scan_id, se.is_successful, se.barcode_value)
            FROM ecommerce_wms.scan_event se
            JOIN ecommerce_wms.picking_operation po ON po.operation_id = se.operation_id
            JOIN ecommerce_wms.picking_task_item pti ON pti.task_item_id = po.task_item_id
            JOIN ecommerce_wms.picking_task pt ON pt.task_id = pti.task_id
            WHERE pt.order_id = p_order_id
            UNION ALL
            SELECT wc.check_datetime, 'weight_check', format('status=%s exp=%s act=%s', wc.check_status, wc.expected_weight, wc.actual_weight)
            FROM ecommerce_wms.weight_check wc
            WHERE wc.order_id = p_order_id
            UNION ALL
            SELECT qc.qc_datetime, 'qc_check', format('result=%s', qc.qc_result)
            FROM ecommerce_wms.qc_check qc
            WHERE qc.order_id = p_order_id
            UNION ALL
            SELECT pk.packing_datetime, 'packing', format('status=%s', pk.packing_status)
            FROM ecommerce_wms.packing pk
            WHERE pk.order_id = p_order_id
            UNION ALL
            SELECT i.incident_datetime, 'incident', format('type=%s stage=%s', i.incident_type, i.detected_stage)
            FROM ecommerce_wms.incident i
            WHERE i.order_id = p_order_id
            UNION ALL
            SELECT ca.action_datetime, 'corrective_action', format('type=%s', ca.action_type)
            FROM ecommerce_wms.corrective_action ca
            JOIN ecommerce_wms.incident i ON i.incident_id = ca.incident_id
            WHERE i.order_id = p_order_id
            UNION ALL
            SELECT ro.return_datetime, 'return_order', format('status=%s reason=%s', ro.return_status, ro.return_reason)
            FROM ecommerce_wms.return_order ro
            WHERE ro.order_id = p_order_id
        )
        SELECT * FROM ev
    ) q
    ORDER BY event_ts, event_kind;
$f$;

-- kpi по ошибкам за интервал дат (with inc потом agg — как в лекции про cte)
CREATE OR REPLACE FUNCTION ecommerce_wms.stage4_error_kpi(
    p_from_ts timestamp without time zone,
    p_to_ts timestamp without time zone
)
RETURNS TABLE (
    incident_type text,
    incidents_cnt bigint,
    orders_affected bigint
)
LANGUAGE sql
AS $f$
    WITH inc AS (
        SELECT i.incident_id, i.order_id, i.incident_type::text AS itype
        FROM ecommerce_wms.incident i
        WHERE i.incident_datetime >= p_from_ts
          AND i.incident_datetime < p_to_ts
    ),
    agg AS (
        SELECT
            inc.itype,
            count(*)::bigint AS incidents_cnt,
            count(DISTINCT inc.order_id)::bigint AS orders_affected
        FROM inc
        GROUP BY inc.itype
    )
    SELECT
        agg.itype AS incident_type,
        agg.incidents_cnt,
        agg.orders_affected
    FROM agg;
$f$;

-- сколько заданий закрыли и среднее время (в секундах) — только completed и только наши stage4 заказы
CREATE OR REPLACE FUNCTION ecommerce_wms.stage4_picking_duration_stats(
    p_from_ts timestamp without time zone,
    p_to_ts timestamp without time zone
)
RETURNS TABLE (
    day_bucket date,
    tasks_completed bigint,
    avg_seconds numeric
)
LANGUAGE sql
AS $f$
    WITH base AS (
        SELECT
            pt.task_id,
            pt.created_at,
            pt.completed_at,
            date_trunc('day', pt.completed_at)::date AS d
        FROM ecommerce_wms.picking_task pt
        WHERE pt.task_status = 'completed'::ecommerce_wms.task_status_type
          AND pt.completed_at IS NOT NULL
          AND pt.completed_at >= p_from_ts
          AND pt.completed_at < p_to_ts
          AND EXISTS (
              SELECT 1
              FROM ecommerce_wms."order" o
              WHERE o.order_id = pt.order_id
                AND o.external_order_no LIKE 'stage4-ext-%'
          )
    ),
    calc AS (
        SELECT
            b.d AS day_bucket,
            count(*)::bigint AS tasks_completed,
            avg(EXTRACT(EPOCH FROM (b.completed_at - b.created_at)))::numeric(18, 2) AS avg_seconds
        FROM base b
        GROUP BY b.d
    )
    SELECT * FROM calc;
$f$;

-- вставка сканов циклом (типа чтобы показать что функция может insert делать)
CREATE OR REPLACE FUNCTION ecommerce_wms.stage4_seed_scan_events_batch(
    p_operation_id bigint,
    p_barcode_prefix text,
    p_n integer
)
RETURNS integer
LANGUAGE plpgsql
AS $f$
DECLARE
    i integer;
BEGIN
    IF p_n IS NULL OR p_n < 1 OR p_n > 50 THEN
        RAISE EXCEPTION 'n не то число, от 1 до 50 надо';
    END IF;
    FOR i IN 1..p_n LOOP
        INSERT INTO ecommerce_wms.scan_event (
            operation_id,
            barcode_value,
            is_successful,
            scan_datetime
        )
        VALUES (
            p_operation_id,
            format('%s-%s', p_barcode_prefix, lpad(i::text, 3, '0')),
            true,
            clock_timestamp()
        );
    END LOOP;
    RETURN p_n;
END;
$f$;

-- наполнение тестом — всё в одной большой функции чтоб не запутаться с порядком fk
-- если уже запускали то выйдет notice и всё (чтоб два раза не вставить)

CREATE OR REPLACE FUNCTION ecommerce_wms.stage4_seed_demo_data()
RETURNS void
LANGUAGE plpgsql
AS $f$
DECLARE
    v_wh bigint;
    z_pick bigint;
    z_res bigint;
    loc_a bigint;
    loc_b bigint;
    loc_c bigint;  -- изначально думали третью ячейку задействовать, не пригодилось
    p1 bigint;
    p2 bigint;
    r_pick bigint;
    r_pack bigint;
    r_qc bigint;
    e_pick bigint;
    e_pack bigint;
    e_qc bigint;
    o1 bigint;
    o2 bigint;
    oi11 bigint;
    oi12 bigint;
    oi21 bigint;
    t1 bigint;
    t2 bigint;
    ti1 bigint;
    ti2 bigint;
    ti3 bigint;
    op1 bigint;
    op2 bigint;
    inc1 bigint;
BEGIN
    IF EXISTS (
        SELECT 1 FROM ecommerce_wms."order" o WHERE o.external_order_no = 'stage4-ext-001'
    ) THEN
        RAISE NOTICE 'уже заливали stage4, второй раз не делаем';
        RETURN;
    END IF;

    INSERT INTO ecommerce_wms.role (role_name) VALUES ('stage4_role_picker')
    ON CONFLICT (role_name) DO NOTHING;
    INSERT INTO ecommerce_wms.role (role_name) VALUES ('stage4_role_packer')
    ON CONFLICT (role_name) DO NOTHING;
    INSERT INTO ecommerce_wms.role (role_name) VALUES ('stage4_role_qc')
    ON CONFLICT (role_name) DO NOTHING;

    SELECT role_id INTO r_pick FROM ecommerce_wms.role WHERE role_name = 'stage4_role_picker' LIMIT 1;
    SELECT role_id INTO r_pack FROM ecommerce_wms.role WHERE role_name = 'stage4_role_packer' LIMIT 1;
    SELECT role_id INTO r_qc FROM ecommerce_wms.role WHERE role_name = 'stage4_role_qc' LIMIT 1;

    INSERT INTO ecommerce_wms.warehouse (warehouse_name) VALUES ('stage4_wh_alpha')
    ON CONFLICT (warehouse_name) DO NOTHING;
    SELECT warehouse_id INTO v_wh FROM ecommerce_wms.warehouse WHERE warehouse_name = 'stage4_wh_alpha' LIMIT 1;

    INSERT INTO ecommerce_wms.storage_zone (warehouse_id, zone_name) VALUES (v_wh, 'stage4_zone_pick')
    ON CONFLICT (warehouse_id, zone_name) DO NOTHING;
    INSERT INTO ecommerce_wms.storage_zone (warehouse_id, zone_name) VALUES (v_wh, 'stage4_zone_reserve')
    ON CONFLICT (warehouse_id, zone_name) DO NOTHING;
    SELECT zone_id INTO z_pick FROM ecommerce_wms.storage_zone WHERE warehouse_id = v_wh AND zone_name = 'stage4_zone_pick' LIMIT 1;
    SELECT zone_id INTO z_res FROM ecommerce_wms.storage_zone WHERE warehouse_id = v_wh AND zone_name = 'stage4_zone_reserve' LIMIT 1;

    INSERT INTO ecommerce_wms.storage_location (zone_id, location_code, location_type)
    VALUES (z_pick, 'stage4-loc-A01', 'pick_face'::ecommerce_wms.location_type_enum)
    ON CONFLICT (location_code) DO NOTHING;
    INSERT INTO ecommerce_wms.storage_location (zone_id, location_code, location_type)
    VALUES (z_pick, 'stage4-loc-A02', 'pick_face'::ecommerce_wms.location_type_enum)
    ON CONFLICT (location_code) DO NOTHING;
    INSERT INTO ecommerce_wms.storage_location (zone_id, location_code, location_type)
    VALUES (z_res, 'stage4-loc-R01', 'reserve'::ecommerce_wms.location_type_enum)
    ON CONFLICT (location_code) DO NOTHING;

    SELECT location_id INTO loc_a FROM ecommerce_wms.storage_location WHERE location_code = 'stage4-loc-A01' LIMIT 1;
    SELECT location_id INTO loc_b FROM ecommerce_wms.storage_location WHERE location_code = 'stage4-loc-A02' LIMIT 1;
    SELECT location_id INTO loc_c FROM ecommerce_wms.storage_location WHERE location_code = 'stage4-loc-R01' LIMIT 1;

    INSERT INTO ecommerce_wms.product (sku_code, product_name, category_name, unit_weight, is_active)
    VALUES ('stage4-sku-001', 'Товар тестовый А (курсовая)', 'разное', 0.250, true)
    ON CONFLICT (sku_code) DO NOTHING;
    INSERT INTO ecommerce_wms.product (sku_code, product_name, category_name, unit_weight, is_active)
    VALUES ('stage4-sku-002', 'Товар тестовый Б (курсовая)', 'разное', 0.180, true)
    ON CONFLICT (sku_code) DO NOTHING;
    SELECT product_id INTO p1 FROM ecommerce_wms.product WHERE sku_code = 'stage4-sku-001' LIMIT 1;
    SELECT product_id INTO p2 FROM ecommerce_wms.product WHERE sku_code = 'stage4-sku-002' LIMIT 1;

    INSERT INTO ecommerce_wms.barcode (product_id, barcode_value, barcode_type)
    VALUES (p1, 'stage4bc001', 'code128'::ecommerce_wms.barcode_type_enum)
    ON CONFLICT (barcode_value) DO NOTHING;
    INSERT INTO ecommerce_wms.barcode (product_id, barcode_value, barcode_type)
    VALUES (p2, 'stage4bc002', 'code128'::ecommerce_wms.barcode_type_enum)
    ON CONFLICT (barcode_value) DO NOTHING;

    INSERT INTO ecommerce_wms.inventory_balance (product_id, location_id, quantity_on_hand, updated_at)
    VALUES (p1, loc_a, 120, '2026-04-20 07:00:00')
    ON CONFLICT (product_id, location_id) DO NOTHING;
    INSERT INTO ecommerce_wms.inventory_balance (product_id, location_id, quantity_on_hand, updated_at)
    VALUES (p2, loc_b, 80, '2026-04-20 07:00:00')
    ON CONFLICT (product_id, location_id) DO NOTHING;

    INSERT INTO ecommerce_wms.employee (full_name, role_id, is_active)
    VALUES ('Сидоров И. — отборщик (тест курса)', r_pick, true);
    SELECT employee_id INTO e_pick FROM ecommerce_wms.employee WHERE full_name = 'Сидоров И. — отборщик (тест курса)' ORDER BY employee_id DESC LIMIT 1;

    INSERT INTO ecommerce_wms.employee (full_name, role_id, is_active)
    VALUES ('Козлов П. — упаковка (тест курса)', r_pack, true);
    SELECT employee_id INTO e_pack FROM ecommerce_wms.employee WHERE full_name = 'Козлов П. — упаковка (тест курса)' ORDER BY employee_id DESC LIMIT 1;

    INSERT INTO ecommerce_wms.employee (full_name, role_id, is_active)
    VALUES ('Морозова А. — ОТК (тест курса)', r_qc, true);
    SELECT employee_id INTO e_qc FROM ecommerce_wms.employee WHERE full_name = 'Морозова А. — ОТК (тест курса)' ORDER BY employee_id DESC LIMIT 1;

    -- сценарий 1 нормальный заказ
    INSERT INTO ecommerce_wms."order" (external_order_no, order_datetime, order_status, expected_total_weight)
    VALUES ('stage4-ext-001', '2026-04-20 08:05:00', 'shipped'::ecommerce_wms.order_status_type, 0.860);
    SELECT order_id INTO o1 FROM ecommerce_wms."order" WHERE external_order_no = 'stage4-ext-001' LIMIT 1;

    INSERT INTO ecommerce_wms.order_item (order_id, product_id, ordered_qty, collected_qty)
    VALUES (o1, p1, 2, 2);
    INSERT INTO ecommerce_wms.order_item (order_id, product_id, ordered_qty, collected_qty)
    VALUES (o1, p2, 2, 2);
    SELECT order_item_id INTO oi11 FROM ecommerce_wms.order_item WHERE order_id = o1 AND product_id = p1 LIMIT 1;
    SELECT order_item_id INTO oi12 FROM ecommerce_wms.order_item WHERE order_id = o1 AND product_id = p2 LIMIT 1;

    INSERT INTO ecommerce_wms.picking_task (order_id, employee_id, task_status, created_at, started_at, completed_at)
    VALUES (
        o1,
        e_pick,
        'completed'::ecommerce_wms.task_status_type,
        '2026-04-20 08:10:00',
        '2026-04-20 08:11:00',
        '2026-04-20 08:22:00'
    );
    SELECT task_id INTO t1 FROM ecommerce_wms.picking_task WHERE order_id = o1 ORDER BY task_id DESC LIMIT 1;

    INSERT INTO ecommerce_wms.picking_task_item (task_id, order_item_id, location_id, planned_qty, picked_qty)
    VALUES (t1, oi11, loc_a, 2, 2);
    INSERT INTO ecommerce_wms.picking_task_item (task_id, order_item_id, location_id, planned_qty, picked_qty)
    VALUES (t1, oi12, loc_b, 2, 2);
    SELECT task_item_id INTO ti1 FROM ecommerce_wms.picking_task_item WHERE task_id = t1 AND order_item_id = oi11 LIMIT 1;
    SELECT task_item_id INTO ti2 FROM ecommerce_wms.picking_task_item WHERE task_id = t1 AND order_item_id = oi12 LIMIT 1;

    INSERT INTO ecommerce_wms.picking_operation (task_item_id, employee_id, operation_datetime, picked_qty, operation_result)
    VALUES (ti1, e_pick, '2026-04-20 08:15:00', 2, 'success'::ecommerce_wms.operation_result_type)
    RETURNING operation_id INTO op1;

    INSERT INTO ecommerce_wms.picking_operation (task_item_id, employee_id, operation_datetime, picked_qty, operation_result)
    VALUES (ti2, e_pick, '2026-04-20 08:18:00', 2, 'success'::ecommerce_wms.operation_result_type);

    INSERT INTO ecommerce_wms.scan_event (operation_id, barcode_value, is_successful, scan_datetime)
    VALUES (op1, 'stage4bc001', true, '2026-04-20 08:15:30');

    INSERT INTO ecommerce_wms.weight_check (order_id, employee_id, expected_weight, actual_weight, deviation_percent, check_status, check_datetime)
    VALUES (o1, e_pack, 0.860, 0.855, 0.58, 'passed'::ecommerce_wms.weight_check_status_type, '2026-04-20 08:30:00');

    INSERT INTO ecommerce_wms.qc_check (order_id, employee_id, qc_result, qc_datetime, comment)
    VALUES (o1, e_qc, 'passed'::ecommerce_wms.qc_result_type, '2026-04-20 08:35:00', 'ок, всё сошлось');

    INSERT INTO ecommerce_wms.packing (order_id, employee_id, packing_datetime, packing_status)
    VALUES (o1, e_pack, '2026-04-20 08:40:00', 'packed'::ecommerce_wms.packing_status_type);

    -- сценарий 2 косяк на отборе + потом вес не прошёл и т.д.
    INSERT INTO ecommerce_wms."order" (external_order_no, order_datetime, order_status, expected_total_weight)
    VALUES ('stage4-ext-002', '2026-04-20 09:00:00', 'on_additional_check'::ecommerce_wms.order_status_type, 0.500);
    SELECT order_id INTO o2 FROM ecommerce_wms."order" WHERE external_order_no = 'stage4-ext-002' LIMIT 1;

    INSERT INTO ecommerce_wms.order_item (order_id, product_id, ordered_qty, collected_qty)
    VALUES (o2, p1, 1, 1);
    SELECT order_item_id INTO oi21 FROM ecommerce_wms.order_item WHERE order_id = o2 AND product_id = p1 LIMIT 1;

    INSERT INTO ecommerce_wms.picking_task (order_id, employee_id, task_status, created_at, started_at, completed_at)
    VALUES (
        o2,
        e_pick,
        'completed'::ecommerce_wms.task_status_type,
        '2026-04-20 09:05:00',
        '2026-04-20 09:06:00',
        '2026-04-20 09:18:00'
    );
    SELECT task_id INTO t2 FROM ecommerce_wms.picking_task WHERE order_id = o2 ORDER BY task_id DESC LIMIT 1;

    INSERT INTO ecommerce_wms.picking_task_item (task_id, order_item_id, location_id, planned_qty, picked_qty)
    VALUES (t2, oi21, loc_a, 1, 1)
    RETURNING task_item_id INTO ti3;

    INSERT INTO ecommerce_wms.picking_operation (task_item_id, employee_id, operation_datetime, picked_qty, operation_result)
    VALUES (ti3, e_pick, '2026-04-20 09:10:00', 1, 'partial'::ecommerce_wms.operation_result_type)
    RETURNING operation_id INTO op2;

    INSERT INTO ecommerce_wms.scan_event (operation_id, barcode_value, is_successful, scan_datetime)
    VALUES (op2, 'stage4bc002', false, '2026-04-20 09:10:15');

    INSERT INTO ecommerce_wms.incident (
        order_id,
        order_item_id,
        operation_id,
        incident_type,
        detected_stage,
        incident_datetime,
        status,
        description
    )
    VALUES (
        o2,
        oi21,
        op2,
        'wrong_item'::ecommerce_wms.incident_type_enum,
        'picking'::ecommerce_wms.detected_stage_enum,
        '2026-04-20 09:11:00',
        'in_progress'::ecommerce_wms.incident_status_type,
        'ошибка: отсканировали не тот штрихкод по сути'
    )
    RETURNING incident_id INTO inc1;

    INSERT INTO ecommerce_wms.corrective_action (incident_id, employee_id, action_type, action_datetime, comment)
    VALUES (
        inc1,
        e_pick,
        're_pick'::ecommerce_wms.corrective_action_type_enum,
        '2026-04-20 09:12:00',
        'решили пересобрать отбор'
    );

    INSERT INTO ecommerce_wms.weight_check (order_id, employee_id, expected_weight, actual_weight, deviation_percent, check_status, check_datetime)
    VALUES (o2, e_pack, 0.500, 0.620, 24.00, 'failed'::ecommerce_wms.weight_check_status_type, '2026-04-20 09:25:00');

    INSERT INTO ecommerce_wms.qc_check (order_id, employee_id, qc_result, qc_datetime, comment)
    VALUES (o2, e_qc, 'requires_rework'::ecommerce_wms.qc_result_type, '2026-04-20 09:28:00', 'вес не сошёлся — на доработку');

    INSERT INTO ecommerce_wms.packing (order_id, employee_id, packing_datetime, packing_status)
    VALUES (o2, e_pack, '2026-04-20 09:20:00', 'repacked'::ecommerce_wms.packing_status_type);

    INSERT INTO ecommerce_wms.return_order (order_id, incident_id, return_reason, return_datetime, return_status)
    VALUES (
        o2,
        inc1,
        'клиент написал что не тот товар',
        '2026-04-20 10:00:00',
        'registered'::ecommerce_wms.return_status_type
    );

    RAISE NOTICE 'готово, заказы stage4-ext-001 и 002';
END;
$f$;

-- заливка
SELECT ecommerce_wms.stage4_seed_demo_data();

-- ниже проверки которые мы в конце дописали (смотреть колонку ok должна true)

-- Ожидается: 3 строки позиций (2 по stage4-ext-001 + 1 по stage4-ext-002).
SELECT 'TEST stage4_vw_order_detail rowcount >= 3' AS test_id,
       count(*) >= 3 AS ok
FROM ecommerce_wms.stage4_vw_order_detail;

-- Ожидается: для заказа stage4-ext-001 нет открытых инцидентов
SELECT 'TEST stage4_order_health order 001' AS test_id,
       ecommerce_wms.stage4_order_health(
           (SELECT order_id FROM ecommerce_wms."order" WHERE external_order_no = 'stage4-ext-001' LIMIT 1)
       ) LIKE '%без открытых%' AS ok;

-- Ожидается: для заказа stage4-ext-002 есть открытый инцидент
SELECT 'TEST stage4_order_health order 002' AS test_id,
       ecommerce_wms.stage4_order_health(
           (SELECT order_id FROM ecommerce_wms."order" WHERE external_order_no = 'stage4-ext-002' LIMIT 1)
       ) LIKE '%есть открытый%' AS ok;

-- Ожидается: таймлайн содержит ключевые виды событий (>= 5 строк для успешного заказа).
SELECT 'TEST stage4_order_timeline events >= 5' AS test_id,
       count(*) >= 5 AS ok
FROM ecommerce_wms.stage4_order_timeline(
    (SELECT order_id FROM ecommerce_wms."order" WHERE external_order_no = 'stage4-ext-001' LIMIT 1)
);

-- Ожидается: KPI по инцидентам за сутки 2026-04-20 содержит wrong_item.
SELECT 'TEST stage4_error_kpi contains wrong_item' AS test_id,
       EXISTS (
           SELECT 1
           FROM ecommerce_wms.stage4_error_kpi('2026-04-20 00:00:00', '2026-04-21 00:00:00') k
           WHERE k.incident_type = 'wrong_item' AND k.incidents_cnt >= 1
       ) AS ok;

-- Ожидается: статистика длительности заданий возвращает >= 1 день.
SELECT 'TEST stage4_picking_duration_stats' AS test_id,
       count(*) >= 1 AS ok
FROM ecommerce_wms.stage4_picking_duration_stats('2026-04-20 00:00:00', '2026-04-21 00:00:00');

-- Дополнительные сканы через функцию-генератор (ожидается: число вставленных = 2)
SELECT 'TEST stage4_seed_scan_events_batch' AS test_id,
       ecommerce_wms.stage4_seed_scan_events_batch(
           (SELECT po.operation_id
            FROM ecommerce_wms.picking_operation po
            JOIN ecommerce_wms.picking_task_item pti ON pti.task_item_id = po.task_item_id
            JOIN ecommerce_wms.picking_task pt ON pt.task_id = pti.task_id
            JOIN ecommerce_wms."order" o ON o.order_id = pt.order_id
            WHERE o.external_order_no = 'stage4-ext-001'
            ORDER BY po.operation_id
            LIMIT 1),
           'stage4extra',
           2
       ) = 2 AS ok;

-- кусок с with ... with ... как «выгрузка» (отдельно view не делали, и так сойдёт)
WITH inc AS (
    SELECT
        i.incident_id,
        i.order_id,
        i.incident_type,
        i.incident_datetime,
        o.external_order_no
    FROM ecommerce_wms.incident i
    JOIN ecommerce_wms."order" o ON o.order_id = i.order_id
    WHERE o.external_order_no LIKE 'stage4-ext-%'
),
loc AS (
    SELECT
        pt.order_id,
        sz.zone_name,
        w.warehouse_name
    FROM ecommerce_wms.picking_task pt
    JOIN ecommerce_wms.picking_task_item pti ON pti.task_id = pt.task_id
    JOIN ecommerce_wms.storage_location sl ON sl.location_id = pti.location_id
    JOIN ecommerce_wms.storage_zone sz ON sz.zone_id = sl.zone_id
    JOIN ecommerce_wms.warehouse w ON w.warehouse_id = sz.warehouse_id
    GROUP BY pt.order_id, sz.zone_name, w.warehouse_name
),
final AS (
    SELECT
        inc.incident_id,
        inc.external_order_no,
        inc.incident_type,
        loc.warehouse_name,
        loc.zone_name
    FROM inc
    LEFT JOIN loc ON loc.order_id = inc.order_id
)
SELECT 'TEST stage4_bi CTE export rows >= 1' AS test_id,
       count(*) >= 1 AS ok
FROM final;
