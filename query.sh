#!/usr/bin/env bash
# 使い方: ./query.sh "SELECT COUNT(*) FROM pos_orders"
#         ./query.sh @query.json   (JSONファイル {"sql": "..."} を渡す場合)
# トークン保護が有効な場合: 環境変数 QUERY_API_TOKEN を設定しておく
set -euo pipefail
URL="https://asia-northeast1-shop-management-475406.cloudfunctions.net/store-analysis/api/query"
HDR=()
if [ -n "${QUERY_API_TOKEN:-}" ]; then HDR=(-H "X-Query-Token: ${QUERY_API_TOKEN}"); fi
if [[ "${1:-}" == @* ]]; then
  curl -sS -X POST "$URL" -H "Content-Type: application/json" "${HDR[@]}" -d "$1"
else
  python3 - "$1" <<'PY' | curl -sS -X POST "$URL" -H "Content-Type: application/json" "${HDR[@]}" -d @-
import json, sys
print(json.dumps({"sql": sys.argv[1]}))
PY
fi
echo
