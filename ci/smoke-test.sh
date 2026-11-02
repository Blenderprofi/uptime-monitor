#!/usr/bin/env bash
# Black-box smoke test of a deployed environment, through its public load balancer.
#
#   ci/smoke-test.sh <base-url>
#
# Proves the whole path works: DNS → ALB → Service → pod → RDS.
set -euo pipefail

BASE_URL="${1:?usage: $0 <base-url>}"
BASE_URL="${BASE_URL%/}"
# A brand-new ALB and its DNS name can take a few minutes to come up.
ATTEMPTS="${SMOKE_ATTEMPTS:-36}"
DELAY_SECONDS="${SMOKE_DELAY_SECONDS:-10}"

echo "Waiting for $BASE_URL to answer..."
for attempt in $(seq 1 "$ATTEMPTS"); do
  if curl -fsS --max-time 5 "$BASE_URL/api/health" >/dev/null 2>&1; then
    break
  fi
  if ((attempt == ATTEMPTS)); then
    echo "FAIL: $BASE_URL not reachable after $((ATTEMPTS * DELAY_SECONDS))s"
    exit 1
  fi
  echo "  attempt $attempt/$ATTEMPTS - not reachable yet"
  sleep "$DELAY_SECONDS"
done

body="$(mktemp)"
trap 'rm -f "$body"' EXIT

# expect <path> <http-status> [text the body must contain]
expect() {
  local path="$1" want="$2" needle="${3:-}" status
  status="$(curl -sS --max-time 10 -o "$body" -w '%{http_code}' "$BASE_URL$path")"
  if [[ "$status" != "$want" ]]; then
    echo "FAIL $path: HTTP $status (expected $want)"
    head -c 500 "$body"
    exit 1
  fi
  if [[ -n "$needle" ]] && ! grep -qF -- "$needle" "$body"; then
    echo "FAIL $path: response does not contain '$needle'"
    head -c 500 "$body"
    exit 1
  fi
  echo "ok   $path -> $status"
}

expect /api/health 200 '"status":"ok"'
expect /api/ready 200 '"database":"ok"' # the pod can reach its RDS database
expect /login 200 'name="csrf"'         # templates render, sessions work
expect /dashboard 303                   # auth guard redirects anonymous users
expect /static/style.css 200

echo "Smoke test passed for $BASE_URL"
