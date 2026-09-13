#!/usr/bin/env bash
# Record HTTP fixtures for the DM-MCP catalog API into
# app/PrivateInventoryTests/Fixtures/ (manual, curl-based — ADR-0006/0007).
#
# Usage:
#   1. Add your curl call(s) below (see the example), adjusting
#      URL, method and headers to the real API.
#   2. Run from the repo root:  ./scripts/record-fixtures.sh
#   3. Commit the resulting files (fixtures are committed so simulator
#      tests need no network — ADR-0006).
#
# Fixtures are plain response bodies (JSON); name them after the
# endpoint + scenario, e.g. catalog_search_schraubendreher.json
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURE_DIR="${SCRIPT_DIR}/../app/PrivateInventoryTests/Fixtures"
mkdir -p "${FIXTURE_DIR}"

# Example: record one catalog search response
# curl -sS -X GET \
#   'https://<host>/catalog/search?query=schraubendreher' \
#   -H 'Authorization: Bearer <token>' \
#   -o "${FIXTURE_DIR}/catalog_search_schraubendreher.json"

# TODO: add the actual recording calls here.

echo "Fixture dir: ${FIXTURE_DIR}"
exit 0
