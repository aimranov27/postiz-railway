#!/usr/bin/env bash
# Starts Postiz on Railway. Compared with the official image's start command
# it adds:
#
# 1. Public port. nginx listens on $PORT (Railway's default is 8080), and the
#    backend is pinned to 3000. Upstream's backend also reads PORT, so
#    without this it grabs nginx's port and the app breaks.
# 2. Start order. Postiz's Temporal workers never retry a failed first
#    connection (gitroomhq/postiz-app#1550, #2035), and Railway starts all
#    services at once. So we wait for Temporal before starting Postiz.
# 3. Account seeding. With DISABLE_REGISTRATION=true, Postiz lets whoever
#    signs up first own the instance. The account from POSTIZ_ADMIN_EMAIL and
#    POSTIZ_ADMIN_PASSWORD is created before the public port opens.
# 4. Login cookies. Postiz sets its cookies on the parent domain
#    (.railway.app for *.up.railway.app). Current browsers reject that
#    because up.railway.app is a public suffix (gitroomhq/postiz-app#1143),
#    and older ones would share the session with every *.railway.app site.
#    nginx rewrites the cookie domain to the host the browser used.
# 5. Worker watchdog. Temporal lists a worker as polling until about five
#    minutes after its last poll. If the "main" queue shows no worker on three
#    checks in a row (about eight minutes), the orchestrator is restarted, so
#    scheduled posts don't stall.
set -euo pipefail

log() { echo "[railway-entrypoint] $*"; }
HELPER=/app/railway/railway-helper.cjs
NGINX_CONF=/etc/nginx/nginx.conf

PUBLIC_PORT="${PORT:-8080}"
export PORT=3000

sed -i -E "s/^([[:space:]]*)listen[[:space:]]+[0-9]+;/\1listen ${PUBLIC_PORT};/" "$NGINX_CONF"
if ! grep -q 'proxy_cookie_domain' "$NGINX_CONF"; then
  sed -i -E 's/^([[:space:]]*)server_name _;/&\n\1proxy_cookie_domain ~.+ $host;/' "$NGINX_CONF"
fi
grep -q "listen ${PUBLIC_PORT};" "$NGINX_CONF" && grep -q 'proxy_cookie_domain' "$NGINX_CONF" \
  || { log "ERROR: could not adjust the nginx config"; exit 1; }

mkdir -p "${UPLOAD_DIRECTORY:-/uploads}"

log "Waiting for Temporal at ${TEMPORAL_ADDRESS:-localhost:7233}"
node "$HELPER" wait-temporal "${TEMPORAL_WAIT_SECONDS:-600}" \
  || { log "ERROR: Temporal is not reachable. Check the Temporal service and TEMPORAL_ADDRESS."; exit 1; }

# Upstream's own start command: database migration, then backend, frontend
# and orchestrator under pm2, then pm2 streams their logs.
cd /app
pnpm run pm2 &
app_pid=$!

shutdown() {
  log "Stopping"
  nginx -s quit 2>/dev/null || true
  pm2 kill >/dev/null 2>&1 || true
  kill "$app_pid" 2>/dev/null || true
  exit 0
}
trap shutdown TERM INT

wait_for() {
  node "$HELPER" wait-http "$1" "${STARTUP_WAIT_SECONDS:-600}" &
  local waiter=$!
  while kill -0 "$waiter" 2>/dev/null; do
    if ! kill -0 "$app_pid" 2>/dev/null; then
      log "ERROR: Postiz exited during startup"
      exit 1
    fi
    sleep 2
  done
  wait "$waiter" || { log "ERROR: the $2 did not start"; exit 1; }
}
wait_for http://127.0.0.1:3000/ backend
wait_for http://127.0.0.1:4200/ frontend

node "$HELPER" seed || exit 1

nginx
log "Postiz $NEXT_PUBLIC_VERSION is ready on port $PUBLIC_PORT"

# pm2 supervises a pnpm wrapper, not the orchestrator itself, so pm2 alone
# would leave a hung orchestrator process running. Find it via /proc.
orchestrator_pids() {
  local p cmd
  for p in /proc/[0-9]*; do
    cmd="$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null)" || continue
    [[ "$cmd" == *dist/apps/orchestrator/src/main.js* ]] && echo "${p#/proc/}"
  done
  return 0
}

restart_orchestrator() {
  local pids
  pm2 stop orchestrator >/dev/null 2>&1 || true
  pids="$(orchestrator_pids)"
  if [ -n "$pids" ]; then
    # shellcheck disable=SC2086
    kill -TERM $pids 2>/dev/null || true
    for _ in $(seq 1 15); do
      [ -z "$(orchestrator_pids)" ] && break
      sleep 1
    done
    pids="$(orchestrator_pids)"
    # shellcheck disable=SC2086
    [ -n "$pids" ] && kill -KILL $pids 2>/dev/null || true
  fi
  pm2 start orchestrator >/dev/null 2>&1 || true
}

watchdog() {
  local misses=0 count
  sleep 180
  while true; do
    if count="$(node "$HELPER" pollers 2>/dev/null)"; then
      if [ "$count" = 0 ]; then misses=$((misses + 1)); else misses=0; fi
      if [ "$misses" -ge 3 ]; then
        log "No worker is polling Temporal. Restarting the orchestrator."
        restart_orchestrator
        misses=0
        sleep 120
      fi
    fi
    sleep 60
  done
}
if [ "${POSTIZ_WORKER_WATCHDOG:-true}" = true ]; then
  watchdog &
fi

wait "$app_pid"
