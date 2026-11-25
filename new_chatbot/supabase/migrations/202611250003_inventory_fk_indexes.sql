-- Stage 1 follow-up: indexes for inventory foreign-key lookup paths.
-- Pending review; do not apply until the user approves this migration.

CREATE INDEX po_lines_sku_idx
    ON inventory.po_lines (sku);
CREATE INDEX purchase_orders_supplier_id_idx
    ON inventory.purchase_orders (supplier_id);
CREATE INDEX sales_history_sku_idx
    ON inventory.sales_history (sku);
CREATE INDEX stock_sku_idx
    ON inventory.stock (sku);
CREATE INDEX supplier_messages_supplier_id_idx
    ON inventory.supplier_messages (supplier_id);
CREATE INDEX supplier_products_sku_idx
    ON inventory.supplier_products (sku);
