WITH so_base AS (
    SELECT 
        DATE(so.stock_opname_datetime) AS so_date,
        COALESCE(st.alternative_name, st.name) AS store,
        rm.code AS sku,
        rm.name AS item,
        uom.code AS uom,
        si.stock_inbound AS inbound,
        si.stock_transfer_out AS tf_out,
        si.stock_return AS reture,
        si.spoil_waste AS sw,
        si.stock_final AS qty_so, 
        us.username AS pic,
        ROW_NUMBER() OVER (
      PARTITION BY
        DATE(so.stock_opname_datetime, 'Asia/Jakarta'),
        st.id,
        rm.id
      ORDER BY so.updated_at DESC
    ) AS rn
    FROM `sgl_publicpublic.stock_opnames` so 
    LEFT JOIN `sgl_publicpublic.reference_dates` rd 
        ON rd.date = DATE(so.stock_opname_datetime, 'Asia/Jakarta')
    LEFT JOIN `sgl_publicpublic.stock_opname_details` si 
        ON si.stock_opname_id = so.id 
    LEFT JOIN `sgl_publicpublic.stores` st 
        ON st.id = so.store_id 
    LEFT JOIN `sgl_publicpublic.raw_materials` rm 
        ON rm.id = si.raw_material_id
    LEFT JOIN `sgl_publicpublic.uoms` uom 
        ON uom.id = rm.uom_id 
    LEFT JOIN `sgl_publicpublic.users` us 
        ON us.id = so.updated_by 
    LEFT JOIN `sgl_publicpublic.regions` r 
        ON r.id = st.region_id
    WHERE 1=1 
        AND DATE(so.stock_opname_datetime, 'Asia/Jakarta')
            BETWEEN DATE_SUB('2026-01-01', INTERVAL 2 DAY) AND '2026-01-31'
        AND COALESCE(st.alternative_name, st.name) NOT IN ('',' ')
        AND st.is_online_sales IS TRUE
        AND st.is_active IS NOT FALSE 
),

so_with_beginning AS (
    SELECT
        *,
        LAG(qty_so) OVER (
            PARTITION BY store, sku
            ORDER BY so_date
        ) AS stock_beginning
    FROM so_base
    WHERE rn = 1 
),
inventory_base AS(
SELECT
    *,
    (COALESCE(stock_beginning, 0) + COALESCE(inbound, 0))
    - (
        COALESCE(tf_out, 0)
        + COALESCE(reture, 0)
        + COALESCE(sw, 0)
        + COALESCE(qty_so, 0)
      ) AS actual_usage
FROM so_with_beginning
ORDER BY sku, so_date, store
),

    
master_sku AS(
    SELECT  
ANY_VALUE(sku) AS sku,
LOWER(TRIM(name)) AS name
FROM `sgl_publicpublic.products`
WHERE deleted_at IS NULL 
GROUP BY LOWER(TRIM(name))
),

penuangan_minyak AS (
    SELECT
    DATE(pm.datetime, 'Asia/Jakarta') AS date,
    COALESCE(`sgl_publicpublic.stores`.alternative_name, `sgl_publicpublic.stores`.name) AS store,
    rm.code AS sku,
    rm.name AS raw_material,
    SUM(pm.quantity) AS penuangan 
    FROM `sgl_publicpublic.stock_oil_pourings` pm 
    LEFT JOIN `sgl_publicpublic.reference_dates` ON `sgl_publicpublic.reference_dates`.date = DATE(pm.created_at, 'Asia/Jakarta')
    LEFT JOIN `sgl_publicpublic.raw_materials` rm ON rm.id = pm.raw_material_id
    LEFT JOIN `sgl_publicpublic.stores` ON `sgl_publicpublic.stores`.id = pm.store_id 
    WHERE 1=1 
        AND DATE(pm.created_at) BETWEEN '2026-01-01' AND '2026-01-31'
        AND pm.deleted_at IS NULL
    GROUP BY date, store, sku, raw_material
    ORDER BY date
),
latest AS (
    SELECT 
        ad.input_date AS date,
        COALESCE(s.alternative_name, s.name) AS store,
        rm.code AS sku_rawmat,
        rm.name AS raw_material,
        ai.quantity,
        ad.updated_at,
        ROW_NUMBER() OVER (
            PARTITION BY ad.input_date, s.id, rm.id
            ORDER BY ad.updated_at DESC
        ) AS rn
    FROM `sgl_publicpublic.stock_adjustments` ad 
    LEFT JOIN `sgl_publicpublic.stock_adjustment_items` ai 
        ON ai.stock_adjustment_id = ad.id 
    LEFT JOIN `sgl_publicpublic.raw_materials` rm 
        ON rm.id = ai.raw_material_id
    LEFT JOIN `sgl_publicpublic.stores` s
        ON s.id = ad.store_id 
    WHERE 
        ad.type = 'oil_pouring'
        AND ad.input_date BETWEEN '2026-01-01' AND '2026-01-31'
        AND ad.deleted_at IS NULL
        AND ad.status = 'approved'
),
revisi AS(
SELECT
    date,
    store,
    sku_rawmat,
    raw_material,
    SUM(quantity) AS revisi
FROM latest
WHERE rn = 1
GROUP BY date, store, sku_rawmat, raw_material
ORDER BY date
),

iu_minyak AS(
    SELECT 
    pm.date, 
    pm.store,
    pm.sku,
    pm.raw_material,
    pm.penuangan AS ideal_usage 
    FROM (SELECT 
        penuangan_minyak.date, 
        penuangan_minyak.store,
        penuangan_minyak.sku,
        penuangan_minyak.raw_material,
        penuangan_minyak.penuangan
    FROM  penuangan_minyak
    LEFT JOIN revisi ON revisi.date = penuangan_minyak.date 
        AND revisi.store = penuangan_minyak.store 
        AND revisi.sku_rawmat = penuangan_minyak.sku 
    WHERE CASE WHEN revisi.date IS NOT NULL THEN 'revisi' ELSE 'actual' END = 'actual'
    UNION ALL 
    SELECT * FROM revisi) pm 
    ORDER BY date, store
),

bom_1 AS (
    SELECT DISTINCT
    bh.sku AS sku_menu,
    rm.code AS sku_rawmat,
    rm.name AS raw_material,
    SUM(bi.quantity) AS qty,
    'bom_1' AS bom_type,
    FROM `sgl_publicpublic.bom_items` bi 
    LEFT JOIN `sgl_publicpublic.bom_headers` bh ON bh.id = bi.bom_header_id
    LEFT JOIN `sgl_publicpublic.raw_materials` rm ON rm.id = bi.raw_material_id
    WHERE bh.deleted_at IS NULL
     AND rm.deleted_at IS NULL
    GROUP BY sku_menu, sku_rawmat, raw_material, bom_type 
),

bom_2 AS(
SELECT 
`Coding Klikit` AS sku_menu,
`Coding IBS` AS sku_rawmat,
Ingredient AS raw_material,
SUM(`Qty Net`) AS qty,
type AS bom_type
FROM `project_dataset.bom_varian`
GROUP BY 1, 2, 3, 5
),

master_bom AS(
SELECT * FROM bom_1
UNION ALL 
SELECT * FROM bom_2
),

main_menu AS (
    SELECT
    CASE 
        WHEN EXTRACT(HOUR FROM salesorder_brands.ordered_at AT TIME ZONE 'Asia/Jakarta') BETWEEN 0 AND 5
        THEN DATE(DATE(salesorder_brands.ordered_at, 'Asia/Jakarta') - INTERVAL 1 DAY)
        ELSE DATE(salesorder_brands.ordered_at, 'Asia/Jakarta')
    END AS date,
    COALESCE(`sgl_publicpublic.stores`.alternative_name, `sgl_publicpublic.stores`.name) AS store,
    sku.sku AS sku_menu,
    LOWER(TRIM(`sgl_publicpublic.salesorder_items`.name)) AS menu_name,
    master_bom.sku_rawmat AS sku_rawmat,
    master_bom.raw_material AS raw_material,
    SUM(`sgl_publicpublic.salesorder_items`.quantity * master_bom.qty) AS item_usage,
    FROM `sgl_publicpublic.salesorder_items`
    JOIN `sgl_publicpublic.salesorder_brands` AS salesorder_brands ON salesorder_brands.id = `sgl_publicpublic.salesorder_items`.salesorder_brand_id
    JOIN `sgl_publicpublic.stores` ON `sgl_publicpublic.stores`.id = salesorder_brands.store_id
    LEFT JOIN `sgl_publicpublic.regions` r ON r.id = `sgl_publicpublic.stores`.region_id
    LEFT JOIN `sgl_publicpublic.reference_dates` ON `sgl_publicpublic.reference_dates`.date = DATE(salesorder_brands.ordered_at, 'Asia/Jakarta')
    LEFT JOIN master_sku sku ON LOWER(TRIM(sku.name)) = LOWER(TRIM(`sgl_publicpublic.salesorder_items`.name))
    LEFT JOIN `project_dataset.mapping_bom_type` mb ON mb.store_id = `sgl_publicpublic.stores`.id
    LEFT JOIN master_bom ON master_bom.sku_menu = sku.sku 
        AND master_bom.bom_type = mb.mapping_bom 
    
    WHERE salesorder_brands.status = 'completed'
    AND salesorder_brands.deleted_at IS NULL 
    AND salesorder_brands.ordered_at >= TIMESTAMP(datetime(DATE_SUB('2026-01-01', INTERVAL 2 DAY), TIME(06,00,00)), 'Asia/Jakarta')
    AND salesorder_brands.ordered_at <= TIMESTAMP(DATETIME(DATE_ADD('2026-01-31', INTERVAL 1 DAY), TIME(05, 59, 59)), 'Asia/Jakarta')
    AND `sgl_publicpublic.stores`.is_online_sales IS TRUE
    GROUP BY date, store, sku_menu, menu_name, sku_rawmat, raw_material
    ORDER BY date, store
),
bom_item AS(

SELECT DISTINCT 
sku_rawmat,
raw_material 
from master_bom
),

modifier AS (
SELECT
    CASE 
        WHEN EXTRACT(HOUR FROM `sgl_publicpublic.salesorder_brands`.ordered_at AT TIME ZONE 'Asia/Jakarta') BETWEEN 0 AND 5
        THEN DATE(DATE(`sgl_publicpublic.salesorder_brands`.ordered_at, 'Asia/Jakarta') - INTERVAL 1 DAY)
        ELSE DATE(`sgl_publicpublic.salesorder_brands`.ordered_at, 'Asia/Jakarta')
    END AS date,
    COALESCE(`sgl_publicpublic.stores`.alternative_name, `sgl_publicpublic.stores`.name) AS store,
    sku.sku AS sku_menu,
    LOWER(TRIM(`sgl_publicpublic.salesorder_item_option_groups`.option_name)) AS menu_name, 
    master_bom.sku_rawmat AS sku_rawmat,
    master_bom.raw_material AS raw_material,
    SUM(`sgl_publicpublic.salesorder_item_option_groups`.subtotal_quantity * master_bom.qty) AS item_usage,
    FROM `sgl_publicpublic.salesorder_item_option_groups`
    JOIN `sgl_publicpublic.salesorder_brands` ON `sgl_publicpublic.salesorder_brands`.id = `sgl_publicpublic.salesorder_item_option_groups`.salesorder_brand_id
    JOIN `sgl_publicpublic.stores` ON `sgl_publicpublic.stores`.id = `sgl_publicpublic.salesorder_brands`.store_id
    LEFT JOIN `sgl_publicpublic.reference_dates` ON `sgl_publicpublic.reference_dates`.date = DATE(`sgl_publicpublic.salesorder_brands`.ordered_at, 'Asia/Jakarta')
    LEFT JOIN master_sku sku ON LOWER(TRIM(sku.name)) = LOWER(TRIM(`sgl_publicpublic.salesorder_item_option_groups`.option_name))
    LEFT JOIN `sgl_publicpublic.regions` r ON r.id = `sgl_publicpublic.stores`.region_id
    LEFT JOIN `project_dataset.mapping_bom_type` mb ON mb.store_id = `sgl_publicpublic.stores`.id
    LEFT JOIN master_bom ON master_bom.sku_menu = sku.sku 
        AND master_bom.bom_type = mb.mapping_bom 
    WHERE `sgl_publicpublic.salesorder_brands`.status = 'completed' 
    AND `sgl_publicpublic.salesorder_brands`.ordered_at >= TIMESTAMP(datetime(DATE_SUB('2026-01-01', INTERVAL 2 DAY), TIME(06,00,00)), 'Asia/Jakarta')
    AND `sgl_publicpublic.salesorder_brands`.ordered_at <= TIMESTAMP(DATETIME(DATE_ADD('2026-01-31', INTERVAL 1 DAY), TIME(05, 59, 59)), 'Asia/Jakarta')
    AND `sgl_publicpublic.stores`.is_online_sales IS TRUE
    AND `sgl_publicpublic.salesorder_brands`.deleted_at IS NULL
    GROUP BY date, store, sku_menu, menu_name, sku_rawmat, raw_material 
    ORDER BY date ASC
),
item_usage AS (
    SELECT * FROM main_menu
    UNION ALL 
    SELECT * FROM modifier
),

ideal_usage AS(
    SELECT 
    item_usage.date,
    item_usage.store, 
    item_usage.sku_rawmat,
    item_usage.raw_material,
    SUM(item_usage.item_usage) AS ideal_usage,
    
    FROM item_usage
    GROUP BY 1, 2, 3, 4
    ORDER BY 1, 2
),
inventory_final AS(
SELECT 
    b.so_date,
    b.store,
    b.sku,
    b.item,
    b.stock_beginning AS beg,
    b.inbound,
    b.tf_out,
    b.reture,
    b.sw,
    b.qty_so,
    b.actual_usage AS actual_usage,
    CASE 
        WHEN LOWER(b.item) LIKE '%minyak%' THEN iu_minyak.ideal_usage 
        ELSE iu.ideal_usage END AS ideal_usage,
    COUNT(*) AS cc
FROM inventory_base b 
LEFT JOIN ideal_usage iu  
    ON iu.date = b.so_date
    AND iu.store = b.store 
    AND iu.sku_rawmat = b.sku
LEFT JOIN iu_minyak On iu_minyak.date = b.so_date
    AND iu_minyak.store = b.store 
    AND iu_minyak.sku = b.sku 
WHERE 1=1 
    AND b.store IS NOT NULL 
GROUP BY 1, 2, 3,4 ,5 ,6 ,7 ,8, 9, 10, 11, 12  
ORDER BY b.store, b.item, b.so_date
),
item_list AS (
  SELECT
    rd.date,
    COALESCE(s.alternative_name, s.name) AS store,
    item.SKU AS sku,
    ANY_VALUE(GENERIC_ITEM) AS raw_material,
    ANY_VALUE(UoM) AS uom,
    CASE WHEN bom_item.sku_rawmat IS NOT NULL THEN 'bom_item' ELSE 'non_bom' END AS item_type 
  FROM project_dataset.item_list_store item
  LEFT JOIN bom_item ON bom_item.sku_rawmat = item.SKU 
  CROSS JOIN `sgl_publicpublic.reference_dates` rd
  CROSS JOIN `sgl_publicpublic.stores` s
  WHERE rd.date BETWEEN '2026-01-01' AND '2026-01-31'
  GROUP BY rd.date, store, sku, item_type
)
SELECT 
it.date,
it.store,
it.sku,
it.raw_material,
inv.beg AS stock_beg,
inv.inbound,
inv.tf_out,
inv.reture,
inv.sw,
qty_so,
inv.actual_usage,
CASE 
 WHEN it.item_type = 'non_bom'
 THEN actual_usage
 ELSE COALESCE(ideal_usage, 0) END AS ideal_usage,
CASE 
 WHEN it.item_type = 'non_bom'
 THEN actual_usage
 ELSE COALESCE(ideal_usage, 0) END - inv.actual_usage AS gap_qty  
FROM item_list it 
LEFT JOIN inventory_final inv ON inv.so_date = it.date 
AND inv.sku = it.sku
AND inv.store = it.store 
WHERE inv.so_date BETWEEN '2026-01-01' AND '2026-01-31'
ORDER BY sku, date 
