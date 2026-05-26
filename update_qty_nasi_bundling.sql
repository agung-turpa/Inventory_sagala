UPDATE ops_support.hub_product_solds AS target
SET
    quantity = source.qty_fixing,
    updated_at = CURRENT_TIMESTAMP()
FROM (

    WITH main_menu AS (

        SELECT
            ps.id,
            ps.item_id,
            ps.quantity AS qty_before,
            ps.quantity * mb.qty AS qty_fixing,
            mb.qty AS qty_bundling
        FROM ops_support.hub_product_solds ps
        LEFT JOIN ops_support.qty_menu_bundling mb
            ON mb.sku = ps.sku_product
        WHERE order_date BETWEEN '2026-01-01' AND '2026-05-26'
            AND ps.sku_product IN (mb.sku)

    ),

    modifier_filterred AS (

        SELECT
            ps.item_id
        FROM ops_support.hub_product_solds ps
        JOIN main_menu mm
            ON mm.item_id = ps.item_id
        WHERE ps.item_id IN (mm.item_id)
            AND LOWER(TRIM(ps.product_name)) IN (
                'nasi putih',
                'nasi merah',
                'nasi seaweed',
                'nasi pedas original',
                'nasi bom pedas original'
            )
        GROUP BY ps.item_id
        HAVING COUNT(ps.item_id) = 1

    )

    SELECT
        ps.id,
        ps.item_id,
        ps.product_name,
        SUM(ps.quantity) AS qty,
        mm.qty_before,
        SUM(mm.qty_before * mm.qty_bundling) AS qty_fixing
    FROM ops_support.hub_product_solds ps
    JOIN main_menu mm
        ON mm.item_id = ps.item_id
    WHERE ps.item_id IN (mm.item_id)
        AND LOWER(TRIM(ps.product_name)) IN (
            'nasi putih',
            'nasi merah',
            'nasi seaweed',
            'nasi pedas original',
            'nasi bom pedas original'
        )
        AND ps.item_id IN (
            (SELECT item_id FROM modifier_filterred)
        )
    GROUP BY 1, 2, 3, 5

) AS source
WHERE target.id = source.id
    AND target.item_id = source.item_id
    AND target.product_name = source.product_name
