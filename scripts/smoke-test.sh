#!/usr/bin/env bash
# Builds both images and runs the whole template (Postgres, Redis, Temporal,
# Postiz) with docker compose, wired the same way as on Railway. Then checks
# what a template user depends on:
#
# - every service starts, and Postiz waits for Temporal
# - the web UI loads and the API answers
# - the seeded account can log in, wrong passwords and strangers can't
# - login cookies are set for the app's own host, not .railway.app
# - the Temporal workers poll and run Postiz's hourly check for missed posts
# - accounts, uploads and Temporal history survive a full restart
#
# Used locally and by CI. Needs docker, curl and jq.
set -euo pipefail
# Note: don't pipe into `grep -q`. It exits on the first match, the writer
# gets SIGPIPE, and pipefail turns a match into a failure.

cd "$(dirname "$0")/.."

export POSTIZ_HOST_PORT="${SMOKE_PORT:-39100}"
export PUBLIC_DOMAIN=postiz-smoke.up.railway.app
export POSTIZ_ADMIN_EMAIL=admin@example.com
export POSTIZ_ADMIN_PASSWORD="smoke-$(openssl rand -hex 8)"
export POSTGRES_PASSWORD="pg-$(openssl rand -hex 8)"
export REDIS_PASSWORD="redis-$(openssl rand -hex 8)"
export JWT_SECRET="$(openssl rand -hex 32)"

BASE="http://127.0.0.1:$POSTIZ_HOST_PORT"
COMPOSE=(docker compose -p postiz-smoke -f docker-compose.yml)
WORK="$(mktemp -d)"

cleanup() {
  "${COMPOSE[@]}" down -v --remove-orphans >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  "${COMPOSE[@]}" logs --no-color --tail 60 temporal postiz >&2 || true
  exit 1
}

# Requests go to the local port but carry the public host name, as they do
# behind Railway's proxy.
http() { curl -sS -H "Host: $PUBLIC_DOMAIN" "$@"; }
status() { http -o /dev/null -w '%{http_code}' "$@"; }

wait_healthy() {
  for _ in $(seq 1 180); do
    [ "$(http "$BASE/api/" 2>/dev/null)" = "App is running!" ] && return 0
    sleep 5
  done
  fail "Postiz did not become healthy within 15 minutes"
}

login() {
  http -D "$WORK/login-headers" -o "$WORK/login-body" -w '%{http_code}' \
    -H 'Content-Type: application/json' \
    -d "$(jq -n --arg e "$POSTIZ_ADMIN_EMAIL" --arg p "$1" '{email: $e, password: $p, provider: "LOCAL"}')" \
    "$BASE/api/auth/login"
}

auth_token() {
  tr -d '\r' < "$WORK/login-headers" | sed -n 's/^[Ss]et-[Cc]ookie: auth=\([^;]*\);.*/\1/p' | head -n1
}

temporal_cli() { "${COMPOSE[@]}" exec -T temporal temporal --address 127.0.0.1:7233 "$@"; }

wait_for_workers() {
  for _ in $(seq 1 60); do
    count="$("${COMPOSE[@]}" exec -T postiz node /app/railway/railway-helper.cjs pollers 2>/dev/null || echo 0)"
    [ "${count:-0}" -gt 0 ] 2>/dev/null && return 0
    sleep 5
  done
  fail "no Temporal worker is polling the main task queue"
}

wait_for_cron_run() {
  for _ in $(seq 1 60); do
    temporal_cli workflow show -w missing-post-workflow -o json 2>/dev/null \
      | grep -iE 'ACTIVITY_TASK_COMPLETED|ActivityTaskCompleted' >/dev/null && return 0
    sleep 5
  done
  fail "the missed-posts workflow never completed an activity, so the workers are not executing work"
}

if [ -z "${SKIP_BUILD:-}" ]; then
  "${COMPOSE[@]}" build
fi

echo "== versions"
docker run --rm --entrypoint sh postiz-smoke-postiz:local -c 'echo "Postiz $NEXT_PUBLIC_VERSION"'
docker run --rm --entrypoint temporal-server postiz-smoke-temporal:local --version

echo "== first boot"
"${COMPOSE[@]}" up -d --quiet-pull >/dev/null 2>&1 || fail "docker compose up failed"
wait_healthy

echo "-- web UI"
http "$BASE/auth/login" | grep -i '<html' >/dev/null || fail "the login page did not load"
[ "$(status "$BASE/auth/register")" = "307" ] || fail "the sign-up page is not redirected to login"

echo "-- seeded account"
[ "$(login "$POSTIZ_ADMIN_PASSWORD")" = "200" ] || fail "login with the seeded account failed: $(cat "$WORK/login-body")"
token="$(auth_token)"
[ -n "$token" ] || fail "login did not set the auth cookie"
cookie_domain="$(tr -d '\r' < "$WORK/login-headers" | sed -n 's/^[Ss]et-[Cc]ookie: auth=.*[Dd]omain=\([^;]*\).*/\1/p' | head -n1)"
[ "${cookie_domain#.}" = "$PUBLIC_DOMAIN" ] || fail "auth cookie domain is '$cookie_domain', browsers would reject it"
http -H "auth: $token" "$BASE/api/user/self" | jq -e --arg e "$POSTIZ_ADMIN_EMAIL" '.email == $e' >/dev/null \
  || fail "/api/user/self did not return the seeded user"
[ "$(login wrong-password)" = "400" ] || fail "login with a wrong password was not rejected"

echo "-- strangers can't register"
http "$BASE/api/auth/can-register" | jq -e '.register == false' >/dev/null || fail "registration is still open"
code="$(status -H 'Content-Type: application/json' \
  -d '{"email":"intruder@example.com","password":"intruder123","company":"Intruder","provider":"LOCAL"}' \
  "$BASE/api/auth/register")"
[ "$code" = "400" ] || fail "a second account could be registered (HTTP $code)"

echo "-- uploads"
printf 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==' \
  | openssl base64 -d -A > "$WORK/pixel.png"
upload="$(http -H "auth: $token" -F "file=@$WORK/pixel.png;type=image/png" "$BASE/api/media/upload-simple")"
upload_path="$(echo "$upload" | jq -r '.path // empty' | sed -E 's#^https?://[^/]+##')"
[ -n "$upload_path" ] || fail "upload failed: $upload"
[ "$(status "$BASE$upload_path")" = "200" ] || fail "uploaded file is not served at $upload_path"

echo "-- Temporal and workers"
"${COMPOSE[@]}" exec -T postiz node -e \
  "fetch('http://127.0.0.1:3002/health/status').then(r => process.exit(r.status === 200 ? 0 : 1), () => process.exit(1))" \
  || fail "orchestrator health check failed"
wait_for_workers
wait_for_cron_run
temporal_cli operator search-attribute list | grep postId >/dev/null || fail "Postiz search attributes are missing in Temporal"
run_id="$(temporal_cli workflow describe -w missing-post-workflow -o json | jq -r '.workflowExecutionInfo.execution.runId')"
[[ "$run_id" =~ ^[0-9a-f-]{36}$ ]] || fail "could not read the missed-posts workflow run ID ($run_id)"

echo "== restart keeps the data"
"${COMPOSE[@]}" down >/dev/null 2>&1
"${COMPOSE[@]}" up -d >/dev/null 2>&1 || fail "docker compose up failed after restart"
wait_healthy
[ "$(login "$POSTIZ_ADMIN_PASSWORD")" = "200" ] || fail "login failed after restart"
http "$BASE/api/auth/can-register" | jq -e '.register == false' >/dev/null || fail "registration reopened after restart"
[ "$(status "$BASE$upload_path")" = "200" ] || fail "uploaded file is gone after restart"
[ "$(temporal_cli workflow describe -w missing-post-workflow -o json | jq -r '.workflowExecutionInfo.execution.runId')" = "$run_id" ] \
  || fail "Temporal lost its workflow history"
wait_for_workers

echo "PASS"
