#!/usr/bin/env bash
# Smoke test a built wadjet image:
#   docker-smoke.sh <image> <reachable-base-url> [extra docker run args...]
set -euo pipefail

IMAGE="$1"
BASE="$2"
shift 2

KEY="wdj_smoke_test"
HASH=$(printf %s "$KEY" | shasum -a 256 | cut -d' ' -f1)

CID=$(docker run -d \
  -e "WADJET_BASE_URL=$BASE" \
  -e "WADJET_API_KEYS={\"$HASH\":\"smoke\"}" \
  "$@" "$IMAGE")
trap 'docker rm -f "$CID" >/dev/null 2>&1 || true' EXIT

STATUS=""
for _ in $(seq 1 60); do
  STATUS=$(docker inspect -f '{{.State.Health.Status}}' "$CID" 2>/dev/null || true)
  [ "$STATUS" = healthy ] && break
  sleep 1
done
if [ "$STATUS" != healthy ]; then
  docker logs "$CID" 2>&1 || true
  echo "container never became healthy (last: ${STATUS:-unknown})" >&2
  exit 1
fi

curl -fsS "$BASE/.well-known/wadjet" | grep -q '"wadjet"'

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"; docker rm -f "$CID" >/dev/null 2>&1 || true' EXIT
printf '\x89PNG\r\n\x1a\nsmoke' > "$TMP/up.png"

RESPONSE=$(curl -fsS -X POST "$BASE/v1/files" \
  -H "Authorization: Bearer $KEY" \
  -H 'Content-Type: image/png' \
  --data-binary @"$TMP/up.png")
URL=$(printf %s "$RESPONSE" | sed -n 's/.*"url":"\([^"]*\)".*/\1/p')
[ -n "$URL" ] || { echo "no url in upload response: $RESPONSE" >&2; docker logs "$CID" 2>&1; exit 1; }

curl -fsS "$URL" -o "$TMP/down.png"
cmp "$TMP/up.png" "$TMP/down.png"

docker logs "$CID" 2>&1
echo "smoke ok: $BASE"
