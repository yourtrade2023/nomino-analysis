# CLAUDE.md — nomino 店舗分析環境（共有版）

このリポジトリ／プロジェクトは、台湾桃園の実店舗 **nomino（JCPark桃園春日・省多多愛地球）** の在庫・売上データを分析するためのものです。Costcoアウトレット品の再販＋Coupang清算ロット＋委託販売を扱う小売店です。

分析はすべて、デプロイ済みCloud Functionの **読み取り専用SQLゲートウェイ** 経由で行います。GCPやDBの資格情報は不要です（このプロジェクトには含まれません）。

## データベース接続（最重要）

PostgreSQL（Cloud SQL）へは直接接続できません。必ず以下のHTTPゲートウェイを使います。

```
POST https://asia-northeast1-shop-management-475406.cloudfunctions.net/store-analysis/api/query
Content-Type: application/json
Body: {"sql": "SELECT ..."}
```

- **SELECT / WITH のみ**実行可能（書き込みキーワードは拒否される）
- 結果は **最大1000行**。集計してから取得すること
- 使用例:

```bash
curl -sS -X POST "https://asia-northeast1-shop-management-475406.cloudfunctions.net/store-analysis/api/query" \
  -H "Content-Type: application/json" \
  -d '{"sql": "SELECT COUNT(*) FROM pos_orders"}'
```

長いSQLはJSONファイルに書いて `-d @file.json` で送るとエスケープ事故を防げる。`query.sh` ヘルパーも利用可。

環境変数 `QUERY_API_TOKEN` が関数側に設定されている場合はヘッダ `X-Query-Token: <トークン>` が必要（トークンは管理者=石川さんから受領）。

## 主要テーブル

| テーブル | 内容 |
|---|---|
| `pos_orders` | 売上明細（1行=1商品行）。主要列: order_id, line_item_id, order_at, order_status, customer_id, product_name, variant_title, sku, vendor, sale_price(売価), list_price(定価), quantity, cost_price(原価), total_price_before_discounts, total_optional_discount / total_shop_discount / total_coupon_discount（注文単位の値引・明細に按分して使う）, price_discount(単品値引), total_price |
| `pos_stocks` | 日次在庫スナップショット。sku, inventory_quantity, product_name, date。**最新日付のみ有効**: `WHERE date = (SELECT MAX(date) FROM pos_stocks)` |
| `pos_products` | POS商品マスタ |
| `product_master` | 統合商品マスタ（46列） |
| `cyberbiz_customers` | 会員マスタ（※2026-04-10の一括取込のみ。以後未同期 → 下記注意参照） |
| `promo_master` / `promo_items` | 販促キャンペーンと対象商品 |
| `bid_scorings` / `bid_history` / `bid_rules` | Coupang清算ロットの入札スコアリング・入札履歴・ルール |
| `sku_blacklist` | 仕入禁止SKU |
| `costco_suppliers`, `inspection_tickets`, `docket_management`, `intake_*` | Costco仕入・検品システム系 |
| `shopify_imported_orders/products` | EC取込データ |

全テーブル一覧は `SELECT table_name FROM information_schema.tables WHERE table_schema='public'`、列定義は `information_schema.columns` で確認できる。

## 集計の約束事（これを外すと数字が合わない）

1. **有効注文のフィルタ**: 必ず `WHERE order_status NOT IN ('cancelled','refunded') AND total_price > 0`
2. **GMV定義**: `SUM(sale_price * quantity)`（値引前）。実現売上は注文単位値引（total_optional/shop/coupon_discount）を控除
3. **vendor名寄せ**: `vendor` がNULL/空欄は **COSTCO扱い**。表記揺れあり（YOUCT%/YOUTW% で始まるSKUもCostco系）
4. **みなし原価**（cost_price<=0 の行に適用、2026-08-31実測較正）: 委託8社（富士器業・IRIS OHYAMA・盈鑽國際・眾志成・AIRMATE・OZAX・瑪莎利亞・Richell）=売価の70% / COSTCO=51% / Coupang=42% / 亞捷・COSTCO JAPAN・YOUTW・巨吉=40% / その他未登録=65%。Costcoの登録原価は「コストコ店頭価格×30%」の計算値
5. **ゲスト客**: `customer_id = 33184025` はPOSの訪客（非会員一括ID）。客数分析では除外か別枠に
6. **スタッフ・元スタッフ除外**（顧客分析時）: customer_id IN (36129233, 37557893, 36557430, 39689659, 36092685)
7. **会員データの注意**: 2026年6月頃に会員登録をLINE経由へ変更したが、LINE↔Cyberbiz会員が未紐付け。`cyberbiz_customers` は4/10時点のスナップショット。**6月以降の「新規会員減・ゲスト比率上昇」は計測の断絶であり需要減ではない**
8. **既知のデータ不備**: 新莊店の仕入データに日付が2026-12になっているタイポあり

## BigQuery側の在庫データ（inventory_T / inventory_T_shop）

倉庫在庫はPostgreSQLではなく **BigQuery**（`yourtrade-prod.yourtrade_dataset`）にあります。`/api/query` はPostgreSQL専用。BQには専用の読み取りゲートウェイ **`/api/bq-query`** を使います（同一ポリシー: SELECT/WITH限定・1000行上限・スキャン上限1GB。テーブル名は `inventory_T` のように非修飾でOK）。

```bash
curl -sS -X POST ".../store-analysis/api/bq-query" \
  -H "Content-Type: application/json" \
  -d '{"sql": "SELECT parent_sku, item_name, SUM(sum_total_qty) AS qty FROM inventory_T WHERE wms_import_date = (SELECT MAX(wms_import_date) FROM inventory_T) GROUP BY 1,2 ORDER BY qty DESC LIMIT 20"}'
```

| テーブル | 内容 |
|---|---|
| `inventory_T` | **NX倉庫（WMS）の在庫マスタ**。約74万行。日次スナップショット |
| `inventory_T_shop` | 同構造の**店舗側在庫**（約3.4万行） |

共通スキーマ: `wms_import_date`(取込日=スナップショット日付), `jancode`, `new_grade`(等級 SS/S/A/B/C), `parent_sku`, `child_sku`, `picking_key_1/2`, `seller_name`(Coupang等), `item_name`, `list_price`, `box_price`, `sum_total_qty`(数量), `inventory_amount`, `order_count`, `expiry_date`(賞味期限)

### 確認方法

```bash
# ① データセット内の全テーブル一覧＋スキーマ
curl -sS "https://asia-northeast1-shop-management-475406.cloudfunctions.net/store-analysis/api/bq-explore"

# ② inventory_T のスキーマ・行数・サンプル5行
curl -sS ".../store-analysis/api/bq-explore?table=inventory_T"

# ③ 賞味期限リスト（inventory_T と inventory_T_shop を統合した加工済みデータ）
curl -sS ".../store-analysis/api/expiry-list"
#    ブラウザ版: .../store-analysis/expiry-list
```

注意点:
- **スナップショット型**なので、最新状態を見るには `wms_import_date` が最新日の行だけを使う（全期間を合算すると数量が何重にもなる）
- 同一SKUでも `expiry_date`（賞味期限ロット）ごとに行が分かれる
- POS側SKUとの突合キーは `jancode`（バーコード）または `parent_sku`/`child_sku`

## 業務定数

- 目標在庫日数30日 / リードタイム7日 / 販売分析窓90日 / 滞留警告60日・危険90日
- 月次売上目標: NT$700万（2026年8月時点）

## ダッシュボード（ブラウザで開ける）

ベースURL: `https://asia-northeast1-shop-management-475406.cloudfunctions.net/store-analysis`

- `/dashboard` — 売上KPI（GMV・粗利・実現粗利率・顧客軸）
- `/member-dashboard` — 会員分析（F2転換など）
- `/promo-master` — 販促マスタ管理
- `/coupang-bid` — Coupang入札スコアリング（Excelアップロード式）
- `/expiry-list` — 賞味期限リスト
- `/health` — 接続ヘルスチェック

## 定番クエリ

`sample_queries.sql` に月次KPI・AOV分解・日次売上・売れ筋・在庫照会などのテンプレートあり。

## してはいけないこと

- このプロジェクトからのコード変更・デプロイ（本体リポジトリ `inventory-analysis` の管轄。デプロイはmainブランチへのpushで自動実行されるため触らない）
- `/api/query` への大量・高頻度アクセス（本番POSと同じDBを見ている）
- 顧客個人情報（氏名・電話・住所）の外部持ち出し
