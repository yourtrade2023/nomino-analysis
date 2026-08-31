-- ============================================================
-- nomino 店舗分析 定番クエリ集
-- 実行方法: ./query.sh "<SQL>" または /api/query へPOST
-- 注意: 結果は最大1000行。必ず集計してから取得すること。
-- ============================================================

-- 【1】月次KPI（GMV・レシート数・AOV・バスケットサイズ）
SELECT to_char(date_trunc('month', order_at), 'YYYY-MM') AS month,
       COUNT(DISTINCT order_id)                            AS receipts,
       ROUND(SUM(sale_price*quantity))                     AS gmv,
       SUM(quantity)                                       AS units,
       ROUND(SUM(sale_price*quantity)/NULLIF(COUNT(DISTINCT order_id),0)) AS aov,
       ROUND(SUM(quantity)::numeric/NULLIF(COUNT(DISTINCT order_id),0),2) AS basket_units
FROM pos_orders
WHERE order_status NOT IN ('cancelled','refunded') AND total_price > 0
GROUP BY 1 ORDER BY 1;

-- 【2】日次売上（直近30日）
SELECT order_at::date AS d,
       COUNT(DISTINCT order_id) AS receipts,
       ROUND(SUM(sale_price*quantity)) AS gmv
FROM pos_orders
WHERE order_status NOT IN ('cancelled','refunded') AND total_price > 0
  AND order_at >= NOW() - INTERVAL '30 days'
GROUP BY 1 ORDER BY 1;

-- 【3】仕入先グループ別GMV（当月）
SELECT CASE WHEN COALESCE(vendor,'') IN ('COSTCO','') OR vendor LIKE 'YOUCT%' OR vendor LIKE 'YOUTW%' THEN 'COSTCO系'
            WHEN vendor IN ('富士器業','IRIS OHYAMA','盈鑽國際','眾志成','AIRMATE','OZAX','瑪莎利亞','Richell') THEN '委託'
            WHEN vendor ILIKE '%coupang%' THEN 'Coupang'
            ELSE 'その他' END AS vendor_group,
       ROUND(SUM(sale_price*quantity)) AS gmv,
       SUM(quantity) AS units
FROM pos_orders
WHERE order_status NOT IN ('cancelled','refunded') AND total_price > 0
  AND date_trunc('month', order_at) = date_trunc('month', NOW())
GROUP BY 1 ORDER BY gmv DESC;

-- 【4】売れ筋トップ20（直近90日・売上高順）
SELECT product_name, vendor,
       SUM(quantity) AS qty,
       ROUND(SUM(sale_price*quantity)) AS gmv
FROM pos_orders
WHERE order_status NOT IN ('cancelled','refunded') AND total_price > 0
  AND order_at >= NOW() - INTERVAL '90 days'
GROUP BY 1,2 ORDER BY gmv DESC LIMIT 20;

-- 【5】売れ筋なのに在庫が薄い商品（欠品リスク）
WITH sales AS (
  SELECT sku, MAX(product_name) AS product_name,
         SUM(quantity)/90.0 AS daily_qty
  FROM pos_orders
  WHERE order_status NOT IN ('cancelled','refunded') AND total_price > 0
    AND order_at >= NOW() - INTERVAL '90 days'
  GROUP BY sku HAVING SUM(quantity) >= 30
), stock AS (
  SELECT sku, inventory_quantity
  FROM pos_stocks WHERE date = (SELECT MAX(date) FROM pos_stocks)
)
SELECT s.product_name, s.sku,
       ROUND(s.daily_qty,1) AS daily_sales,
       COALESCE(st.inventory_quantity,0) AS stock,
       ROUND(COALESCE(st.inventory_quantity,0)/NULLIF(s.daily_qty,0),1) AS days_left
FROM sales s LEFT JOIN stock st USING (sku)
WHERE COALESCE(st.inventory_quantity,0) < s.daily_qty * 7
ORDER BY days_left NULLS FIRST LIMIT 50;

-- 【6】粗利率（みなし原価適用・月次）
--   委託8社=70% / COSTCO(空欄含む)=51% / Coupang=42% / 亞捷・COSTCO JAPAN・YOUTW・巨吉=40% / その他=65%（2026-08-31実測較正）
SELECT to_char(date_trunc('month', order_at), 'YYYY-MM') AS month,
       ROUND(SUM(sale_price*quantity)) AS gmv,
       ROUND(SUM((sale_price - CASE
         WHEN cost_price > 0 THEN cost_price
         WHEN vendor IN ('富士器業','IRIS OHYAMA','盈鑽國際','眾志成','AIRMATE','OZAX','瑪莎利亞','Richell') THEN sale_price*0.70
         WHEN COALESCE(vendor,'') IN ('COSTCO','') THEN sale_price*0.51
         WHEN vendor ILIKE '%coupang%' THEN sale_price*0.42
         WHEN vendor IN ('亞捷','COSTCO JAPAN','YOUTW','巨吉') THEN sale_price*0.40
         ELSE sale_price*0.65 END) * quantity)) AS gross_profit,
       ROUND(100.0 * SUM((sale_price - CASE
         WHEN cost_price > 0 THEN cost_price
         WHEN vendor IN ('富士器業','IRIS OHYAMA','盈鑽國際','眾志成','AIRMATE','OZAX','瑪莎利亞','Richell') THEN sale_price*0.70
         WHEN COALESCE(vendor,'') IN ('COSTCO','') THEN sale_price*0.51
         WHEN vendor ILIKE '%coupang%' THEN sale_price*0.42
         WHEN vendor IN ('亞捷','COSTCO JAPAN','YOUTW','巨吉') THEN sale_price*0.40
         ELSE sale_price*0.65 END) * quantity) / NULLIF(SUM(sale_price*quantity),0), 1) AS margin_pct
FROM pos_orders
WHERE order_status NOT IN ('cancelled','refunded') AND total_price > 0
GROUP BY 1 ORDER BY 1;

-- 【7】値引き総額（注文単位・月次）※注文単位値引は注文ごとに1回だけ数える
SELECT to_char(date_trunc('month', o.order_at), 'YYYY-MM') AS month,
       ROUND(SUM(o.opt + o.shop + o.coup)) AS order_level_discount
FROM (
  SELECT DISTINCT order_id, order_at,
         COALESCE(total_optional_discount,0) AS opt,
         COALESCE(total_shop_discount,0)     AS shop,
         COALESCE(total_coupon_discount,0)   AS coup
  FROM pos_orders
  WHERE order_status NOT IN ('cancelled','refunded') AND total_price > 0
) o
GROUP BY 1 ORDER BY 1;

-- 【8】顧客ランキング（直近90日・スタッフとゲスト除外）
SELECT customer_id,
       COUNT(DISTINCT order_id) AS orders,
       ROUND(SUM(sale_price*quantity)) AS spend
FROM pos_orders
WHERE order_status NOT IN ('cancelled','refunded') AND total_price > 0
  AND order_at >= NOW() - INTERVAL '90 days'
  AND customer_id <> 33184025
  AND customer_id NOT IN (36129233, 37557893, 36557430, 39689659, 36092685)
GROUP BY 1 ORDER BY spend DESC LIMIT 50;
