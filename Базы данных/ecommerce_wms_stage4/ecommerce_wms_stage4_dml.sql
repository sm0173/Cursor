

SET client_encoding = 'UTF8';

CREATE OR REPLACE VIEW ecommerce_wms.stage4_vw_order_detail AS
SELECT
    o.order_id,
    o.external_order_no,
    o.order_datetime,
    o.order_status,
    oi.ordered_qty,
    oi.collected_qty,
    p.sku_code,
    p.product_name
FROM ecommerce_wms."order" o
JOIN ecommerce_wms.order_item oi ON oi.order_id = o.order_id
JOIN ecommerce_wms.product p ON p.product_id = oi.product_id
WHERE o.external_order_no LIKE 'stage4-ext-%';

CREATE OR REPLACE VIEW ecommerce_wms.stage4_vw_incident_return AS
SELECT
    o.external_order_no,
    i.incident_type,
    i.status AS incident_status,
    ro.return_reason,
    ro.return_status
FROM ecommerce_wms."order" o
LEFT JOIN ecommerce_wms.incident i ON i.order_id = o.order_id
LEFT JOIN ecommerce_wms.return_order ro ON ro.order_id = o.order_id
WHERE o.external_order_no LIKE 'stage4-ext-%';

CREATE OR REPLACE FUNCTION ecommerce_wms.stage4_order_line_count(p_order_id bigint)
RETURNS bigint
LANGUAGE sql
AS $f$
    SELECT count(*)::bigint
    FROM ecommerce_wms.order_item oi
    WHERE oi.order_id = p_order_id;
$f$;

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
        RETURN format('id=%s строк=%s открытый инцидент', p_order_id, c);
    END IF;
    RETURN format('id=%s строк=%s без открытых инцидентов', p_order_id, c);
END;
$f$;

CREATE OR REPLACE FUNCTION ecommerce_wms.stage4_order_timeline(p_order_id bigint)
RETURNS TABLE (
    event_ts timestamp without time zone,
    event_kind text,
    event_detail text
)
LANGUAGE sql
AS $f$
    SELECT o.order_datetime, 'order'::text, o.order_status::text
    FROM ecommerce_wms."order" o
    WHERE o.order_id = p_order_id
    UNION ALL
    SELECT pt.completed_at, 'picking_task', pt.task_status::text
    FROM ecommerce_wms.picking_task pt
    WHERE pt.order_id = p_order_id AND pt.completed_at IS NOT NULL
    UNION ALL
    SELECT po.operation_datetime, 'picking_operation', po.operation_result::text
    FROM ecommerce_wms.picking_operation po
    JOIN ecommerce_wms.picking_task_item pti ON pti.task_item_id = po.task_item_id
    JOIN ecommerce_wms.picking_task pt ON pt.task_id = pti.task_id
    WHERE pt.order_id = p_order_id
    UNION ALL
    SELECT wc.check_datetime, 'weight_check', wc.check_status::text
    FROM ecommerce_wms.weight_check wc
    WHERE wc.order_id = p_order_id
    UNION ALL
    SELECT qc.qc_datetime, 'qc_check', qc.qc_result::text
    FROM ecommerce_wms.qc_check qc
    WHERE qc.order_id = p_order_id;
$f$;

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
        RAISE NOTICE 'stage4 уже загружен';
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

    INSERT INTO ecommerce_wms.product (sku_code, product_name, category_name, unit_weight, is_active)
    VALUES ('stage4-sku-001', 'Тест А', 'прочее', 0.250, true)
    ON CONFLICT (sku_code) DO NOTHING;
    INSERT INTO ecommerce_wms.product (sku_code, product_name, category_name, unit_weight, is_active)
    VALUES ('stage4-sku-002', 'Тест Б', 'прочее', 0.180, true)
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
    VALUES ('Сотрудник 1', r_pick, true);
    SELECT employee_id INTO e_pick FROM ecommerce_wms.employee WHERE full_name = 'Сотрудник 1' ORDER BY employee_id DESC LIMIT 1;

    INSERT INTO ecommerce_wms.employee (full_name, role_id, is_active)
    VALUES ('Сотрудник 2', r_pack, true);
    SELECT employee_id INTO e_pack FROM ecommerce_wms.employee WHERE full_name = 'Сотрудник 2' ORDER BY employee_id DESC LIMIT 1;

    INSERT INTO ecommerce_wms.employee (full_name, role_id, is_active)
    VALUES ('Сотрудник 3', r_qc, true);
    SELECT employee_id INTO e_qc FROM ecommerce_wms.employee WHERE full_name = 'Сотрудник 3' ORDER BY employee_id DESC LIMIT 1;

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
    VALUES (o1, e_qc, 'passed'::ecommerce_wms.qc_result_type, '2026-04-20 08:35:00', 'ok');

    INSERT INTO ecommerce_wms.packing (order_id, employee_id, packing_datetime, packing_status)
    VALUES (o1, e_pack, '2026-04-20 08:40:00', 'packed'::ecommerce_wms.packing_status_type);

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
        'тест'
    )
    RETURNING incident_id INTO inc1;

    INSERT INTO ecommerce_wms.corrective_action (incident_id, employee_id, action_type, action_datetime, comment)
    VALUES (
        inc1,
        e_pick,
        're_pick'::ecommerce_wms.corrective_action_type_enum,
        '2026-04-20 09:12:00',
        'тест'
    );

    INSERT INTO ecommerce_wms.weight_check (order_id, employee_id, expected_weight, actual_weight, deviation_percent, check_status, check_datetime)
    VALUES (o2, e_pack, 0.500, 0.620, 24.00, 'failed'::ecommerce_wms.weight_check_status_type, '2026-04-20 09:25:00');

    INSERT INTO ecommerce_wms.qc_check (order_id, employee_id, qc_result, qc_datetime, comment)
    VALUES (o2, e_qc, 'requires_rework'::ecommerce_wms.qc_result_type, '2026-04-20 09:28:00', 'тест');

    INSERT INTO ecommerce_wms.packing (order_id, employee_id, packing_datetime, packing_status)
    VALUES (o2, e_pack, '2026-04-20 09:20:00', 'repacked'::ecommerce_wms.packing_status_type);

    INSERT INTO ecommerce_wms.return_order (order_id, incident_id, return_reason, return_datetime, return_status)
    VALUES (
        o2,
        inc1,
        'тест',
        '2026-04-20 10:00:00',
        'registered'::ecommerce_wms.return_status_type
    );

    RAISE NOTICE 'stage4-ext-001, stage4-ext-002';
END;
$f$;

SELECT ecommerce_wms.stage4_seed_demo_data();

SELECT 'TEST vw_order_detail' AS test_id,
       count(*) >= 3 AS ok
FROM ecommerce_wms.stage4_vw_order_detail;

SELECT 'TEST order_health 001' AS test_id,
       ecommerce_wms.stage4_order_health(
           (SELECT order_id FROM ecommerce_wms."order" WHERE external_order_no = 'stage4-ext-001' LIMIT 1)
       ) LIKE '%без открытых%' AS ok;

SELECT 'TEST order_health 002' AS test_id,
       ecommerce_wms.stage4_order_health(
           (SELECT order_id FROM ecommerce_wms."order" WHERE external_order_no = 'stage4-ext-002' LIMIT 1)
       ) LIKE '%открытый инцидент%' AS ok;

SELECT 'TEST order_timeline' AS test_id,
       count(*) >= 4 AS ok
FROM ecommerce_wms.stage4_order_timeline(
    (SELECT order_id FROM ecommerce_wms."order" WHERE external_order_no = 'stage4-ext-001' LIMIT 1)
);

SELECT 'TEST incident type wrong_item' AS test_id,
       count(*) >= 1 AS ok
FROM ecommerce_wms.incident i
JOIN ecommerce_wms."order" o ON o.order_id = i.order_id
WHERE o.external_order_no = 'stage4-ext-002'
  AND i.incident_type = 'wrong_item'::ecommerce_wms.incident_type_enum;

WITH x AS (
    SELECT i.incident_type::text AS t, count(*)::bigint AS n
    FROM ecommerce_wms.incident i
    JOIN ecommerce_wms."order" o ON o.order_id = i.order_id
    WHERE o.external_order_no LIKE 'stage4-ext-%'
    GROUP BY i.incident_type
)
SELECT 'TEST CTE group by' AS test_id,
       coalesce(sum(n), 0) >= 1 AS ok
FROM x;
