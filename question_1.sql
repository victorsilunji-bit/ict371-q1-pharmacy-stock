-- ============================================================================
-- ICT371 Advanced Database - Question 1: Pharmacy Stock and Daily Sales
-- ============================================================================

-- (a) Database and seed data (Tables & Constraints)
CREATE TABLE medicines (
    medicine_id   SERIAL PRIMARY KEY,
    medicine_name VARCHAR(120) NOT NULL UNIQUE,
    unit_price    NUMERIC(10, 2) NOT NULL CHECK (unit_price > 0),
    stock_qty     INTEGER NOT NULL CHECK (stock_qty >= 0)
);

CREATE TABLE sales (
    sale_id     SERIAL PRIMARY KEY,
    medicine_id INTEGER NOT NULL REFERENCES medicines(medicine_id),
    quantity    INTEGER NOT NULL CHECK (quantity > 0),
    unit_price  NUMERIC(10, 2) NOT NULL CHECK (unit_price > 0),
    sold_on     DATE NOT NULL DEFAULT CURRENT_DATE
);

CREATE TABLE stock_audit (
    audit_id    SERIAL PRIMARY KEY,
    medicine_id INTEGER NOT NULL REFERENCES medicines(medicine_id),
    old_qty     INTEGER NOT NULL,
    new_qty     INTEGER NOT NULL,
    changed_at  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE daily_sales (
    sales_date   DATE PRIMARY KEY,
    total_qty    INTEGER NOT NULL CHECK (total_qty >= 0),
    total_amount NUMERIC(12, 2) NOT NULL CHECK (total_amount >= 0)
);

-- (b) Function: fn_sale_value
CREATE OR REPLACE FUNCTION fn_sale_value(
    p_medicine_id INTEGER,
    p_quantity    INTEGER
) RETURNS NUMERIC(12, 2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_unit_price NUMERIC(10, 2);
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Quantity must be a positive integer (got: %)', p_quantity;
    END IF;

    SELECT unit_price
      INTO v_unit_price
      FROM medicines
     WHERE medicine_id = p_medicine_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown medicine_id: %', p_medicine_id;
    END IF;

    RETURN ROUND(v_unit_price * p_quantity, 2);
END;
$$;

-- (c) Procedure: pr_record_sale
CREATE OR REPLACE PROCEDURE pr_record_sale(
    p_medicine_id INTEGER,
    p_quantity    INTEGER,
    p_sold_on     DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_unit_price NUMERIC(10, 2);
    v_stock_qty  INTEGER;
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Sale quantity must be positive.';
    END IF;

    IF p_sold_on IS NULL THEN
        RAISE EXCEPTION 'Sale date cannot be NULL.';
    END IF;

    -- Lock row to prevent concurrent overselling
    SELECT unit_price, stock_qty
      INTO v_unit_price, v_stock_qty
      FROM medicines
     WHERE medicine_id = p_medicine_id
       FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Medicine ID % does not exist.', p_medicine_id;
    END IF;

    IF v_stock_qty < p_quantity THEN
        RAISE EXCEPTION 'Insufficient stock for medicine ID % (Available: %, Requested: %)',
            p_medicine_id, v_stock_qty, p_quantity;
    END IF;

    -- Insert sale with current unit price
    INSERT INTO sales (medicine_id, quantity, unit_price, sold_on)
    VALUES (p_medicine_id, p_quantity, v_unit_price, p_sold_on);

    -- Deduct stock exactly once
    UPDATE medicines
       SET stock_qty = stock_qty - p_quantity
     WHERE medicine_id = p_medicine_id;
END;
$$;

-- (d) Trigger: AFTER UPDATE row trigger on medicines
CREATE OR REPLACE FUNCTION trg_fn_audit_medicine_stock()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.stock_qty IS DISTINCT FROM OLD.stock_qty THEN
        INSERT INTO stock_audit (medicine_id, old_qty, new_qty, changed_at)
        VALUES (NEW.medicine_id, OLD.stock_qty, NEW.stock_qty, CURRENT_TIMESTAMP);
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_medicines_stock_audit
AFTER UPDATE OF stock_qty ON medicines
FOR EACH ROW
EXECUTE FUNCTION trg_fn_audit_medicine_stock();

-- (a continued) Seed Data: 3 medicines and 6 valid sales loaded via procedure
INSERT INTO medicines (medicine_name, unit_price, stock_qty) VALUES
    ('Paracetamol 500mg', 15.00, 25),
    ('Amoxicillin 250mg', 45.00, 14),
    ('Ibuprofen 400mg',   20.00, 30);

CALL pr_record_sale(1, 10, CURRENT_DATE - INTERVAL '2 days');
CALL pr_record_sale(1, 8,  CURRENT_DATE - INTERVAL '1 day');
CALL pr_record_sale(2, 6,  CURRENT_DATE - INTERVAL '1 day');
CALL pr_record_sale(2, 3,  CURRENT_DATE);
CALL pr_record_sale(3, 5,  CURRENT_DATE);
CALL pr_record_sale(3, 4,  CURRENT_DATE);

-- (e) View: v_low_stock
CREATE OR REPLACE VIEW v_low_stock AS
SELECT medicine_name,
       unit_price,
       stock_qty AS remaining_stock
  FROM medicines
 WHERE stock_qty < 10;

-- Query view after sales
SELECT * FROM v_low_stock;

-- (f) Index and EXPLAIN
-- Justification: A composite B-tree index on (medicine_id, sold_on) allows PostgreSQL
-- to seek directly to the target medicine_id and perform a contiguous range scan on sold_on.
CREATE INDEX idx_sales_medicine_sold_on ON sales (medicine_id, sold_on);

EXPLAIN ANALYZE
SELECT sale_id, quantity, unit_price, sold_on
  FROM sales
 WHERE medicine_id = 1
   AND sold_on BETWEEN CURRENT_DATE - INTERVAL '7 days' AND CURRENT_DATE;

-- (g) Scheduled Job: pr_refresh_sales
CREATE OR REPLACE PROCEDURE pr_refresh_sales(p_day DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_total_qty    INTEGER;
    v_total_amount NUMERIC(12, 2);
BEGIN
    SELECT COALESCE(SUM(quantity), 0),
           COALESCE(SUM(quantity * unit_price), 0.00)
      INTO v_total_qty, v_total_amount
      FROM sales
     WHERE sold_on = p_day;

    INSERT INTO daily_sales (sales_date, total_qty, total_amount)
    VALUES (p_day, v_total_qty, v_total_amount)
    ON CONFLICT (sales_date) DO UPDATE
       SET total_qty    = EXCLUDED.total_qty,
           total_amount = EXCLUDED.total_amount;
END;
$$;

-- Schedule daily at 00:15 for the previous day (requires pg_cron)
SELECT cron.schedule(
    'refresh_pharmacy_daily_sales',
    '15 0 * * *',
    $$CALL pr_refresh_sales(CURRENT_DATE - 1);$$
);