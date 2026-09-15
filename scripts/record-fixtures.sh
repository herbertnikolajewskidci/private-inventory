#!/usr/bin/env bash
# Record HTTP fixtures for the catalog sources (dm MCP, dm search API,
# OpenBeautyFacts/OpenFoodFacts) into
# app/PrivateInventoryTests/Fixtures/ (manual, curl-based — ADR-0006/0007).
#
# Usage:
#   1. Run:  ./scripts/record-fixtures.sh
#   2. Commit the resulting files (fixtures are committed so simulator
#      tests need no network — ADR-0006).
#
# Conventions:
#   - Fixtures are plain response bodies, named
#     <source>_<scenario>.json (e.g. dm_mcp_product_hit.json).
#   - The dm MCP endpoint answers with Server-Sent Events, so its
#     fixtures are raw SSE bodies ("event: message" + "data: {...}").
#   - Response headers a test relies on (the dm search cache-control,
#     the dm MCP Mcp-Session-Id) are recorded next to the body as
#     <name>.headers.txt.
#   - Malformed responses are synthetic (corrupted on purpose), so they
#     live inline in the test files, not in this directory.
#
# Recording a handful of single requests against public endpoints is the
# manual maintenance ADR-0006 assumes; it is not bulk access. For
# OBF/OFF the production rule "1 API call = 1 real scan" applies to the
# app, not to this script.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURE_DIR="${SCRIPT_DIR}/../app/PrivateInventoryTests/Fixtures"
mkdir -p "${FIXTURE_DIR}"

UA="private-inventory-fixture-recording/1.0 (github.com/herbertnikolajewskidci/private-inventory)"
MCP_URL="https://mcp.dm.de/mcp"
MCP_PROTOCOL_VERSION="2025-06-18"
MCP_JSON_HEADERS=(
  -H "Content-Type: application/json"
  -H "Accept: application/json, text/event-stream"
)

record_request() {
  local expected="$1"
  shift
  local status
  status=$(curl -sS --max-time 30 -w "%{http_code}" "$@")
  if [[ ! " ${expected} " =~ " ${status} " ]]; then
    echo "error: expected HTTP ${expected} but got ${status}" >&2
    exit 1
  fi
}

# ----------------------------------------------------------------------
# 1. dm MCP server (official, Streamable HTTP, no auth)
#    Endpoint and sequence: docs/research/dm-mcp-swift-anbindung.md
# ----------------------------------------------------------------------

# 1.1 initialize: starts the session. The server answers with the
# Mcp-Session-Id header and an SSE body carrying the JSON-RPC result.
INIT_BODY='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"'"${MCP_PROTOCOL_VERSION}"'","capabilities":{},"clientInfo":{"name":"private-inventory-fixture-recording","version":"1.0.0"}}}'
record_request 200 -X POST "${MCP_URL}" "${MCP_JSON_HEADERS[@]}" \
  -D "${FIXTURE_DIR}/dm_mcp_initialize.headers.txt" \
  -d "${INIT_BODY}" \
  -o "${FIXTURE_DIR}/dm_mcp_initialize.json"
echo "recorded dm_mcp_initialize.{json,headers.txt}"

# The session id for the follow-up calls comes from the recorded
# response headers (lower-case names with curl --http2).
SESSION_ID="$(awk -F': ' 'tolower($1) == "mcp-session-id" {print $2}' \
  "${FIXTURE_DIR}/dm_mcp_initialize.headers.txt" | tr -d '\r' | tr -d ' ')"
if [[ -z "${SESSION_ID}" ]]; then
  echo "error: no Mcp-Session-Id in the initialize response headers" >&2
  exit 1
fi
echo "session: ${SESSION_ID}"

# 1.2 notifications/initialized: acknowledges the handshake (HTTP 202,
# empty body — nothing to record).
record_request "200 202" -X POST "${MCP_URL}" "${MCP_JSON_HEADERS[@]}" \
  -H "Mcp-Session-Id: ${SESSION_ID}" \
  -H "MCP-Protocol-Version: ${MCP_PROTOCOL_VERSION}" \
  -d '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  -o /dev/null

# 1.3 tools/call getProductDetails — known dm product (hit).
# gtins must be [Int64]; a string fails server-side schema validation.
record_request 200 -X POST "${MCP_URL}" "${MCP_JSON_HEADERS[@]}" \
  -H "Mcp-Session-Id: ${SESSION_ID}" \
  -H "MCP-Protocol-Version: ${MCP_PROTOCOL_VERSION}" \
  -d '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"getProductDetails","arguments":{"gtins":[4066447966008]}}}' \
  -o "${FIXTURE_DIR}/dm_mcp_product_hit.json"
echo "recorded dm_mcp_product_hit.json"

# 1.4 tools/call getProductDetails — unknown GTIN (miss: found=false,
# no error at the JSON-RPC level).
record_request 200 -X POST "${MCP_URL}" "${MCP_JSON_HEADERS[@]}" \
  -H "Mcp-Session-Id: ${SESSION_ID}" \
  -H "MCP-Protocol-Version: ${MCP_PROTOCOL_VERSION}" \
  -d '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"getProductDetails","arguments":{"gtins":[9999999999999]}}}' \
  -o "${FIXTURE_DIR}/dm_mcp_product_miss.json"
echo "recorded dm_mcp_product_miss.json"

# 1.5 tools/call with an unknown session id (HTTP 404 "Session not
# found" — the re-handshake trigger of the Swift client).
record_request 404 -X POST "${MCP_URL}" "${MCP_JSON_HEADERS[@]}" \
  -H "Mcp-Session-Id: 00000000000000000000000000000000" \
  -H "MCP-Protocol-Version: ${MCP_PROTOCOL_VERSION}" \
  -d '{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"getProductDetails","arguments":{"gtins":[4066447966008]}}}' \
  -o "${FIXTURE_DIR}/dm_mcp_session_expired.json"
echo "recorded dm_mcp_session_expired.json (expect HTTP 404 body)"

# 1.6 tools/call without the session header (HTTP 400 "Missing session
# ID" — guards the client's invariant that the session is set first).
record_request 400 -X POST "${MCP_URL}" "${MCP_JSON_HEADERS[@]}" \
  -d '{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"getProductDetails","arguments":{"gtins":[4066447966008]}}}' \
  -o "${FIXTURE_DIR}/dm_mcp_session_missing.json"
echo "recorded dm_mcp_session_missing.json (expect HTTP 400 body)"

# ----------------------------------------------------------------------
# 2. dm search API (unofficial backend of dm.de; GTIN as query)
#    docs/research/barcode-product-data-sources.md — the 4-day
#    cache-control header is part of the contract; it is recorded
#    because the client must respect it (ticket #13).
# ----------------------------------------------------------------------

record_request 200 \
  'https://product-search.services.dmtech.com/de/search/crawl?query=4066447966008&pageSize=5&currentPage=0&type=search-static' \
  -H "User-Agent: ${UA}" \
  -D "${FIXTURE_DIR}/dm_search_product_hit.headers.txt" \
  -o "${FIXTURE_DIR}/dm_search_product_hit.json"
echo "recorded dm_search_product_hit.{json,headers.txt}"

record_request "200 404" \
  'https://product-search.services.dmtech.com/de/search/crawl?query=9999999999999&pageSize=5&currentPage=0&type=search-static' \
  -H "User-Agent: ${UA}" \
  -D "${FIXTURE_DIR}/dm_search_product_miss.headers.txt" \
  -o "${FIXTURE_DIR}/dm_search_product_miss.json"
echo "recorded dm_search_product_miss.{json,headers.txt}"

# ----------------------------------------------------------------------
# 3. OpenBeautyFacts / OpenFoodFacts (ODbL; same Product Opener API)
#    Hit fixtures are real products with name, brand and front image;
#    the miss is a dm GTIN that neither database knows (HTTP 404 with
#    body {"status":0,...}).
# ----------------------------------------------------------------------

record_request 200 \
  'https://world.openbeautyfacts.org/api/v2/product/80466468.json' \
  -H "User-Agent: ${UA}" \
  -o "${FIXTURE_DIR}/openbeautyfacts_product_hit.json"
echo "recorded openbeautyfacts_product_hit.json (DOVE deodorant)"

record_request "200 404" \
  'https://world.openbeautyfacts.org/api/v2/product/4066447966008.json' \
  -H "User-Agent: ${UA}" \
  -o "${FIXTURE_DIR}/openbeautyfacts_product_miss.json"
echo "recorded openbeautyfacts_product_miss.json (expect status:0)"

record_request 200 \
  'https://world.openfoodfacts.org/api/v2/product/3017620422003.json' \
  -H "User-Agent: ${UA}" \
  -o "${FIXTURE_DIR}/openfoodfacts_product_hit.json"
echo "recorded openfoodfacts_product_hit.json (Nutella)"

record_request "200 404" \
  'https://world.openfoodfacts.org/api/v2/product/4066447966008.json' \
  -H "User-Agent: ${UA}" \
  -o "${FIXTURE_DIR}/openfoodfacts_product_miss.json"
echo "recorded openfoodfacts_product_miss.json (expect status:0)"

echo "Fixture dir: ${FIXTURE_DIR}"
