#!/usr/bin/env bash
# BigQuery用クエリヘルパー（/api/query のBQ版）
# 使い方: ./bq_query.sh "SELECT COUNT(*) FROM \`yourtrade-prod.yourtrade_dataset.inventory_T\`"
#         ./bq_query.sh @query.json   (JSONファイル {"sql": "..."} を渡す場合)
# 注意: テーブル名は `yourtrade-prod.yourtrade_dataset.<table>` とバッククォートで完全修飾すること
set -euo pipefail
URL="https://asia-northeast1-shop-management-475406.cloudfunctions.net/store-analysis/api/bq-query"
if [[ "${1:-}" == @* ]]; then
  curl -sS -X POST "$URL" -H "Content-Type: application/json" -d "$1"
else
  python3 - "$1" <<'PY' | curl -sS -X POST "$URL" -H "Content-Type: application/json" -d @-
import json, sys
print(json.dumps({"sql": sys.argv[1]}))
PY
fi
echo
