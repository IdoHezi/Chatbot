-- Stage 1 corrective migration: allow the PO line loop record to access its value column.
-- Pending review; apply only after approval.

CREATE OR REPLACE FUNCTION inventory.create_purchase_order(
    p_supplier_id text,
    p_idempotency_key text,
    p_lines jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog, inventory
AS $function$
DECLARE
    v_state inventory.demo_state%ROWTYPE;
    v_existing inventory.purchase_orders%ROWTYPE;
    v_item jsonb;
    v_unsorted_lines jsonb := '[]'::jsonb;
    v_requested_lines jsonb;
    v_priced_lines jsonb := '[]'::jsonb;
    v_seen_skus text[] := ARRAY[]::text[];
    v_sku text;
    v_quantity_text text;
    v_quantity integer;
    v_pack_size integer;
    v_moq integer;
    v_lead_days integer;
    v_max_lead_days integer := 0;
    v_unit_price numeric(12, 2);
    v_cap integer;
    v_active boolean;
    v_already_ordered bigint;
    v_budget_used numeric(12, 2);
    v_ordering_fee numeric(12, 2);
    v_shipping_fee numeric(12, 2);
    v_threshold numeric(12, 2);
    v_merchandise numeric(12, 2) := 0;
    v_total numeric(12, 2);
    v_order_id uuid := gen_random_uuid();
    v_line record;
BEGIN
    IF p_supplier_id IS NULL OR btrim(p_supplier_id) = '' THEN
        RAISE EXCEPTION 'A supplier is required' USING ERRCODE = '22023';
    END IF;
    IF p_idempotency_key IS NULL OR length(btrim(p_idempotency_key)) NOT BETWEEN 1 AND 160 THEN
        RAISE EXCEPTION 'A non-empty idempotency key of at most 160 characters is required'
            USING ERRCODE = '22023';
    END IF;
    IF p_lines IS NULL OR jsonb_typeof(p_lines) IS DISTINCT FROM 'array'
       OR jsonb_array_length(p_lines) < 1 OR jsonb_array_length(p_lines) > 12 THEN
        RAISE EXCEPTION 'Order lines must be an array with 1 to 12 entries'
            USING ERRCODE = '22023';
    END IF;

    -- Locking the singleton serializes budget and cumulative-cap reservations.
    SELECT * INTO v_state FROM inventory.demo_state WHERE singleton FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Demo state is not initialized' USING ERRCODE = '55000';
    END IF;

    FOR v_item IN SELECT value FROM jsonb_array_elements(p_lines)
    LOOP
        IF jsonb_typeof(v_item) IS DISTINCT FROM 'object'
           OR jsonb_typeof(v_item -> 'sku') IS DISTINCT FROM 'string'
           OR jsonb_typeof(v_item -> 'quantity') IS DISTINCT FROM 'number'
           OR (v_item - 'sku' - 'quantity') <> '{}'::jsonb THEN
            RAISE EXCEPTION 'Each line must contain only string sku and integer quantity'
                USING ERRCODE = '22023';
        END IF;
        v_sku := upper(btrim(v_item ->> 'sku'));
        v_quantity_text := v_item ->> 'quantity';
        IF v_sku = '' OR v_quantity_text IS NULL
           OR length(v_quantity_text) > 9
           OR v_quantity_text !~ '^[1-9][0-9]*$' THEN
            RAISE EXCEPTION 'SKU and positive integer quantity are required'
                USING ERRCODE = '22023';
        END IF;
        v_quantity := v_quantity_text::integer;
        IF v_sku = ANY(v_seen_skus) THEN
            RAISE EXCEPTION 'Duplicate SKU line: %', v_sku USING ERRCODE = '22023';
        END IF;
        v_seen_skus := array_append(v_seen_skus, v_sku);
        v_unsorted_lines := v_unsorted_lines || jsonb_build_array(
            jsonb_build_object('sku', v_sku, 'quantity', v_quantity));
    END LOOP;

    SELECT COALESCE(jsonb_agg(value ORDER BY (value ->> 'sku')), '[]'::jsonb)
      INTO v_requested_lines
      FROM jsonb_array_elements(v_unsorted_lines);

    SELECT * INTO v_existing
      FROM inventory.purchase_orders
     WHERE run_id = v_state.run_id AND idempotency_key = btrim(p_idempotency_key)
     FOR UPDATE;
    IF FOUND THEN
        IF v_existing.supplier_id <> upper(btrim(p_supplier_id))
           OR v_existing.request_payload <> v_requested_lines THEN
            RAISE EXCEPTION 'Idempotency key was reused with a changed payload'
                USING ERRCODE = '23505';
        END IF;
        RETURN jsonb_build_object(
            'order_id', v_existing.order_id,
            'supplier_id', v_existing.supplier_id,
            'status', v_existing.status,
            'merchandise_total', v_existing.merchandise_total,
            'order_fee', v_existing.order_fee,
            'shipping_fee', v_existing.shipping_fee,
            'total_amount', v_existing.total_amount,
            'due_on', v_existing.due_on,
            'idempotent_replay', true
        );
    END IF;

    IF NOT EXISTS (SELECT 1 FROM inventory.suppliers
                   WHERE supplier_id = upper(btrim(p_supplier_id))) THEN
        RAISE EXCEPTION 'Unknown supplier' USING ERRCODE = '23503';
    END IF;

    FOR v_item IN SELECT value FROM jsonb_array_elements(v_requested_lines)
    LOOP
        v_sku := v_item ->> 'sku';
        v_quantity := (v_item ->> 'quantity')::integer;
        SELECT p.cumulative_cap_units, p.active
          INTO v_cap, v_active
          FROM inventory.products AS p
         WHERE p.sku = v_sku;
        IF NOT FOUND OR NOT v_active THEN
            RAISE EXCEPTION 'Unknown or inactive SKU: %', v_sku USING ERRCODE = '23503';
        END IF;

        SELECT sp.pack_size, sp.moq_units, sp.lead_time_days, pb.unit_price
          INTO v_pack_size, v_moq, v_lead_days, v_unit_price
          FROM inventory.supplier_products AS sp
          JOIN LATERAL (
              SELECT b.unit_price
                FROM inventory.price_breaks AS b
               WHERE b.supplier_id = sp.supplier_id
                 AND b.sku = sp.sku
                 AND b.minimum_quantity <= v_quantity
               ORDER BY b.minimum_quantity DESC
               LIMIT 1
          ) AS pb ON true
         WHERE sp.supplier_id = upper(btrim(p_supplier_id))
           AND sp.sku = v_sku
           AND sp.available;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Supplier % cannot supply SKU % at quantity %',
                upper(btrim(p_supplier_id)), v_sku, v_quantity USING ERRCODE = '23503';
        END IF;
        IF v_quantity < v_moq OR mod(v_quantity, v_pack_size) <> 0 THEN
            RAISE EXCEPTION 'SKU % quantity % violates MOQ % or pack size %',
                v_sku, v_quantity, v_moq, v_pack_size USING ERRCODE = '22023';
        END IF;

        SELECT COALESCE(sum(l.quantity), 0)
          INTO v_already_ordered
          FROM inventory.po_lines AS l
         WHERE l.run_id = v_state.run_id AND l.sku = v_sku;
        IF v_already_ordered + v_quantity > v_cap THEN
            RAISE EXCEPTION 'SKU % cumulative cap % would be exceeded', v_sku, v_cap
                USING ERRCODE = '23514';
        END IF;

        v_merchandise := v_merchandise + v_quantity * v_unit_price;
        v_max_lead_days := greatest(v_max_lead_days, v_lead_days);
        v_priced_lines := v_priced_lines || jsonb_build_array(
            jsonb_build_object(
                'sku', v_sku,
                'quantity', v_quantity,
                'unit_price', v_unit_price
            )
        );
    END LOOP;

    SELECT s.ordering_fee, s.shipping_fee, s.free_shipping_threshold
      INTO v_ordering_fee, v_shipping_fee, v_threshold
      FROM inventory.suppliers AS s
     WHERE s.supplier_id = upper(btrim(p_supplier_id));
    IF v_merchandise < v_threshold THEN
        -- Keep the configured fee; otherwise the threshold earns free shipping.
        NULL;
    ELSE
        v_shipping_fee := 0;
    END IF;
    v_total := v_merchandise + v_ordering_fee + v_shipping_fee;

    SELECT COALESCE(sum(o.total_amount), 0)
      INTO v_budget_used
      FROM inventory.purchase_orders AS o
     WHERE o.run_id = v_state.run_id;
    IF v_budget_used + v_total > v_state.budget_limit THEN
        RAISE EXCEPTION 'Order total % exceeds remaining shared budget %',
            v_total, v_state.budget_limit - v_budget_used USING ERRCODE = '23514';
    END IF;

    INSERT INTO inventory.purchase_orders (
        run_id, order_id, supplier_id, status, idempotency_key, request_payload,
        created_on, due_on, merchandise_total, order_fee, shipping_fee
    ) VALUES (
        v_state.run_id, v_order_id, upper(btrim(p_supplier_id)), 'draft',
        btrim(p_idempotency_key), v_requested_lines,
        v_state.simulated_date, v_state.simulated_date + v_max_lead_days,
        v_merchandise, v_ordering_fee, v_shipping_fee
    );

    FOR v_line IN SELECT value FROM jsonb_array_elements(v_priced_lines)
    LOOP
        INSERT INTO inventory.po_lines (run_id, order_id, sku, quantity, unit_price)
        VALUES (
            v_state.run_id, v_order_id, v_line.value ->> 'sku',
            (v_line.value ->> 'quantity')::integer,
            (v_line.value ->> 'unit_price')::numeric(12, 2)
        );
    END LOOP;

    RETURN jsonb_build_object(
        'order_id', v_order_id,
        'supplier_id', upper(btrim(p_supplier_id)),
        'status', 'draft',
        'merchandise_total', v_merchandise,
        'order_fee', v_ordering_fee,
        'shipping_fee', v_shipping_fee,
        'total_amount', v_total,
        'due_on', v_state.simulated_date + v_max_lead_days,
        'idempotent_replay', false
    );
END;
$function$;