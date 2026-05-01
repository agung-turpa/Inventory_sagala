WITH params AS (
  SELECT
    DATE_SUB(CURRENT_DATE(), INTERVAL 31 DAY) AS start_date,
    CURRENT_DATE() AS end_date
),

bom_mapping AS (
  SELECT 
    store_id,
    bom_type,
    version,
    start_date,
    COALESCE(end_date, '2099-12-30') AS end_date
  FROM ops_support.store_mapping_bom
),

-- 1️⃣ Ambil raw SO data (tanpa beginning & actual dari sistem)
inventory_raw AS (
  SELECT 
    DATE(so.stock_opname_datetime)    AS date,
    s.id                              AS store_id,
    rm.id                             AS rawmat_id,
    COALESCE(s.alternative_name, s.name) AS store,
    rm.code                           AS sku,
    rm.name                           AS generik_item,
    uo.code                           AS uom,
    COALESCE(sd.stock_inbound, 0)      AS inbound,
    COALESCE(sd.stock_transfer_out, 0) AS tf_out,
    COALESCE(sd.stock_return, 0)       AS reture,
    COALESCE(sd.spoil_waste, 0)        AS sw,
    COALESCE(sd.stock_final, 0)        AS final_stock
  FROM sgl_publicpublic.stock_opname_details sd  
  LEFT JOIN sgl_publicpublic.stock_opnames so 
    ON so.id = sd.stock_opname_id
  LEFT JOIN sgl_publicpublic.stores s 
    ON s.id = so.store_id 
  LEFT JOIN sgl_publicpublic.raw_materials rm 
    ON rm.id = sd.raw_material_id
  LEFT JOIN sgl_publicpublic.uoms uo 
    ON uo.id = rm.uom_id
  WHERE DATE(so.stock_opname_datetime) BETWEEN DATE_SUB((SELECT start_date FROM params), INTERVAL 1 DAY) AND (SELECT end_date FROM params)
    AND s.is_online_sales IS TRUE
    AND s.is_active IS NOT FALSE
),

inventory_with_beginning AS (
  SELECT
    *,
    LAG(final_stock) OVER (
      PARTITION BY store_id, rawmat_id
      ORDER BY date
    ) AS beginning
  FROM inventory_raw
),

inventory AS (
  SELECT
    date,
    store,
    sku,
    generik_item,
    uom,
    COALESCE(beginning, 0) AS beg,
    inbound,
    tf_out,
    reture,
    sw,
    final_stock,
    (
      COALESCE(beginning, 0)
      + inbound
      - (reture + sw + tf_out + final_stock)
    ) AS actual_usage
  FROM inventory_with_beginning
  CROSS JOIN params p
  WHERE date BETWEEN p.start_date AND p.end_date
),

spicy AS (
  SELECT
    date,
    store,
    CASE 
      WHEN sku IN ('SSP0001', 'SSP0004', 'SSP0005') THEN 'SPICY01' 
      WHEN sku IN ('ABD0192', 'ABD0193', 'ABD0185') THEN 'GPK01' 
    END AS sku,
    CASE 
      WHEN sku IN ('SSP0001', 'SSP0004', 'SSP0005') THEN 'Ayam Spicy Total' 
      WHEN sku IN ('ABD0192', 'ABD0193', 'ABD0185') THEN 'Ayam Geprek Total' 
    END AS generik_item,
    uom,
    SUM(beg)          AS beg,
    SUM(inbound)      AS inbound,
    SUM(tf_out)       AS tf_out,
    SUM(reture)       AS reture,
    SUM(sw)           AS sw,
    SUM(final_stock)  AS final_stock,
    SUM(actual_usage) AS actual_usage
  FROM inventory
  WHERE sku IN ('ABD0192', 'ABD0193', 'ABD0185', 'SSP0001', 'SSP0004', 'SSP0005')
  GROUP BY 1, 2, 3, 4, 5
),

inventory_base AS (
  SELECT * FROM inventory
  UNION ALL
  SELECT * FROM spicy
),

master_bom AS (
  SELECT 
    sku,
    menu,
    sku_rawmat,
    raw_material,
    SUM(qty) AS qty,
    bom_id,
    version
  FROM ops_support.bom_versioning bv
  WHERE version = 'v1'
  AND bom_id = 'bom_2'
  GROUP BY 1, 2, 3, 4, 6, 7

UNION ALL

SELECT
 bh.sku AS sku,
 bh.name AS menu,
 rm.code AS sku_rawmat,
 rm.name AS raw_material,
 SUM(bi.quantity) AS qty,
 'bom_1' AS bom_id,
 'v1' AS version
FROM sgl_publicpublic.bom_headers bh
LEFT JOIN sgl_publicpublic.bom_items bi
  ON bi.bom_header_id = bh.id
LEFT JOIN sgl_publicpublic.raw_materials rm 
  ON rm.id = bi.raw_material_id
WHERE bh.deleted_at IS NULL 
AND bi.deleted_at IS NULL 
AND rm.deleted_at IS NULL
AND bh.sku NOT IN('MOD0224', 'MOD0225')
GROUP BY 1, 2, 3, 4, 6, 7
),

ideal AS(
  SELECT 
  CASE WHEN ps.order_hour BETWEEN 0 AND 6 THEN ps.order_date - INTERVAL 1 DAY
  ELSE ps.order_date END AS date,
  ps.store,
  bom.sku_rawmat,
  bom.raw_material,
  SUM(ps.quantity * bom.qty) AS ideal_usage

  FROM ops_support.hub_product_solds ps 
  LEFT JOIN bom_mapping mb 
    ON mb.store_id = ps.store_id
    AND ps.order_date BETWEEN mb.start_date AND mb.end_date 
  LEFT JOIN master_bom bom 
    ON bom.bom_id = mb.bom_type
    AND bom.sku = ps.sku_product
  WHERE CASE WHEN ps.order_hour BETWEEN 0 AND 6 THEN ps.order_date - INTERVAL 1 DAY
  ELSE ps.order_date END BETWEEN (SELECT start_date FROM params) AND (SELECT end_date FROM params)
  GROUP BY 1, 2, 3, 4
),

iu_spicy AS (
  SELECT 
    date,
    store,
    CASE 
      WHEN sku_rawmat IN ('SSP0001', 'SSP0004', 'SSP0005') THEN 'SPICY01' 
      WHEN sku_rawmat IN ('ABD0192', 'ABD0193', 'ABD0185') THEN 'GPK01' 
    END AS sku_rawmat,
    CASE 
      WHEN sku_rawmat IN ('SSP0001', 'SSP0004', 'SSP0005') THEN 'Ayam Spicy Total' 
      WHEN sku_rawmat IN ('ABD0192', 'ABD0193', 'ABD0185') THEN 'Ayam Geprek Total' 
    END AS raw_material,
    SUM(ideal_usage) AS ideal_usage
  FROM ideal
  WHERE sku_rawmat IN ('ABD0192', 'ABD0193', 'ABD0185', 'SSP0001', 'SSP0004', 'SSP0005')
  GROUP BY 1, 2, 3, 4 
),

ideal_usage AS (
  SELECT * FROM ideal
  UNION ALL 
  SELECT * FROM iu_spicy
),

penuangan_minyak AS (
  SELECT
    DATE(pm.datetime, 'Asia/Jakarta') AS date,
    COALESCE(s.alternative_name, s.name) AS store,
    rm.code AS sku,
    rm.name AS raw_material,
    SUM(pm.quantity) AS penuangan 
  FROM sgl_publicpublic.stock_oil_pourings pm 
  LEFT JOIN sgl_publicpublic.raw_materials rm ON rm.id = pm.raw_material_id
  LEFT JOIN sgl_publicpublic.stores s ON s.id = pm.store_id 
  CROSS JOIN params p
  WHERE pm.deleted_at IS NULL
    AND DATE(pm.created_at) BETWEEN p.start_date AND p.end_date
  GROUP BY 1, 2, 3, 4
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
  FROM sgl_publicpublic.stock_adjustments ad 
  LEFT JOIN sgl_publicpublic.stock_adjustment_items ai ON ai.stock_adjustment_id = ad.id 
  LEFT JOIN sgl_publicpublic.raw_materials rm ON rm.id = ai.raw_material_id
  LEFT JOIN sgl_publicpublic.stores s ON s.id = ad.store_id 
  CROSS JOIN params p 
  WHERE ad.type = 'oil_pouring'
    AND ad.input_date BETWEEN p.start_date AND p.end_date
    AND ad.deleted_at IS NULL
    AND ad.status = 'approved'
),

revisi AS (
  SELECT
    date,
    store,
    sku_rawmat,
    raw_material,
    SUM(quantity) AS revisi
  FROM latest
  WHERE rn = 1
  GROUP BY 1, 2, 3, 4
),

iu_minyak AS (
  SELECT 
    pm.date, 
    pm.store,
    pm.sku,
    pm.raw_material,
    SUM(pm.penuangan) AS ideal_usage 
  FROM (
    SELECT 
      pnm.date, 
      pnm.store,
      pnm.sku,
      pnm.raw_material,
      pnm.penuangan
    FROM penuangan_minyak pnm
    LEFT JOIN revisi ON revisi.date = pnm.date 
      AND revisi.store = pnm.store 
      AND revisi.sku_rawmat = pnm.sku 
    WHERE CASE WHEN revisi.date IS NOT NULL THEN 'revisi' ELSE 'actual' END = 'actual'
    UNION ALL 
    SELECT * FROM revisi
  ) pm 
  GROUP BY 1, 2, 3, 4
),

pdb_base AS (
  SELECT 
    date,
    code,
    quantity
  FROM sgl_publicpublic.pdb_rate_details 
  CROSS JOIN params p
  WHERE date BETWEEN p.start_date AND p.end_date
),

pdb_spicy AS (
  SELECT 
    date,
    CASE 
      WHEN code = 'SSP0004' THEN 'SPICY01'
      WHEN code = 'ABD0185' THEN 'GPK01'
      ELSE code 
    END AS code,
    quantity
  FROM pdb_base
  WHERE code IN ('SSP0004', 'ABD0185')
),

pdb AS (
  SELECT * FROM pdb_base
  UNION ALL
  SELECT * FROM pdb_spicy
),

anulir_clean AS (
  SELECT
    sku,
    status_anulir,
    start_date,
    end_date,
    TRIM(store_item) AS store
  FROM ops_support.anulir_item_gap,
  UNNEST(SPLIT(store, ',')) store_item
),

final_data AS (
  SELECT 
    inv.date,
    inv.store,
    inv.sku,
    inv.generik_item,
    inv.beg,
    inv.inbound,
    inv.tf_out,
    inv.reture,
    inv.sw,
    inv.final_stock AS qty_so,
    inv.actual_usage,
    CASE 
      WHEN inv.sku IN ('KCH1031', 'KCH1032', 'KCH1016') THEN im.ideal_usage
      ELSE iu.ideal_usage
    END AS ideal_usage,
    (CASE 
      WHEN inv.sku IN ('KCH1031', 'KCH1032', 'KCH1016') THEN COALESCE(im.ideal_usage, 0)
      ELSE COALESCE(iu.ideal_usage, 0)
    END - inv.actual_usage) AS gap_qty,
    (CASE 
      WHEN inv.sku IN ('KCH1031', 'KCH1032', 'KCH1016') THEN COALESCE(im.ideal_usage, 0)
      ELSE COALESCE(iu.ideal_usage, 0)
    END - inv.actual_usage) * pdb.quantity AS gap_value,
    an.status_anulir
  FROM inventory_base inv 
  LEFT JOIN ideal_usage iu 
    ON iu.date = inv.date 
    AND iu.store = inv.store 
    AND iu.sku_rawmat = inv.sku 
  LEFT JOIN iu_minyak im 
    ON im.date = inv.date 
    AND im.store = inv.store 
    AND im.sku = inv.sku 
  LEFT JOIN pdb 
    ON pdb.date = inv.date 
    AND pdb.code = inv.sku
  LEFT JOIN project_dataset.item_list_store lis
    ON lis.SKU = inv.sku
  LEFT JOIN anulir_clean an
    ON an.sku = inv.sku
    AND inv.date BETWEEN an.start_date AND an.end_date
    AND inv.store = an.store
  WHERE inv.generik_item IS NOT NULL
    AND lis.item_Type = 'bom'
)

SELECT 
  date,
  store,
  sku,
  generik_item,
  beg,
  inbound,
  tf_out,
  reture,
  sw,
  qty_so,
  actual_usage,
  CASE WHEN sku IN('SSP0001', 'SSP0004', 'SSP0005','ABD0192', 'ABD0193', 'ABD0185') THEN actual_usage ELSE ideal_usage END AS ideal_usage,
  gap_qty,
  CASE WHEN status_anulir IS TRUE THEN 0 ELSE gap_value END AS gap_value
FROM final_data
ORDER BY date, store, generik_item;
