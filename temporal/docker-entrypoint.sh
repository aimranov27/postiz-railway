#!/bin/sh
# Starts a single-node Temporal server backed by Postgres.
#
# On every boot it creates the two databases if they are missing, applies any
# schema migrations, starts the server and makes sure the namespace exists.
# All steps are idempotent, so redeploys and version bumps need no manual work.
set -eu

log() { echo "[railway-temporal] $*"; }

: "${POSTGRES_SEEDS:?Set POSTGRES_SEEDS to the Postgres host}"
: "${POSTGRES_USER:?Set POSTGRES_USER}"
: "${POSTGRES_PWD:?Set POSTGRES_PWD}"
export DB_PORT="${DB_PORT:-5432}"

# Listen on all IPv4 and IPv6 addresses so the service is reachable over
# Railway's private network in both new (dual-stack) and older (IPv6-only)
# environments. Single node, so the cluster talks to itself over loopback.
export BIND_ON_IP="${BIND_ON_IP:-::}"
export TEMPORAL_BROADCAST_ADDRESS="${TEMPORAL_BROADCAST_ADDRESS:-127.0.0.1}"
# Temporal's HTTP API doubles as the health check endpoint on Railway's $PORT.
export FRONTEND_HTTP_PORT="${PORT:-7243}"
GRPC_ADDRESS="127.0.0.1:${FRONTEND_GRPC_PORT:-7233}"

export SQL_PASSWORD="$POSTGRES_PWD"
# The schema tool logs every SQL statement. Only show that output on failure.
sql_tool() {
  if ! temporal-sql-tool --plugin "$DB" --ep "$POSTGRES_SEEDS" -p "$DB_PORT" -u "$POSTGRES_USER" "$@" >/tmp/sql-tool.log 2>&1; then
    cat /tmp/sql-tool.log >&2
    return 1
  fi
}

log "Waiting for Postgres at $POSTGRES_SEEDS:$DB_PORT"
attempt=0
until sql_tool --db "$DBNAME" create 2>/dev/null; do
  attempt=$((attempt + 1))
  if [ "$attempt" -ge 60 ]; then
    cat /tmp/sql-tool.log >&2
    log "ERROR: could not reach Postgres or create the '$DBNAME' database"
    exit 1
  fi
  sleep 3
done
sql_tool --db "$VISIBILITY_DBNAME" create

log "Applying schema migrations"
sql_tool --db "$DBNAME" setup-schema -v 0.0
sql_tool --db "$DBNAME" update-schema -d /etc/temporal/schema/postgresql/v12/temporal/versioned
sql_tool --db "$VISIBILITY_DBNAME" setup-schema -v 0.0
sql_tool --db "$VISIBILITY_DBNAME" update-schema -d /etc/temporal/schema/postgresql/v12/visibility/versioned
unset SQL_PASSWORD
rm -f /tmp/sql-tool.log

log "Starting Temporal $(temporal-server --version 2>/dev/null | awk '{print $NF}')"
temporal-server --allow-no-auth start &
server_pid=$!
trap 'kill -TERM "$server_pid" 2>/dev/null; wait "$server_pid"; exit 0' TERM INT

attempt=0
until temporal operator cluster health --address "$GRPC_ADDRESS" >/dev/null 2>&1; do
  if ! kill -0 "$server_pid" 2>/dev/null; then
    log "ERROR: Temporal exited during startup"
    exit 1
  fi
  attempt=$((attempt + 1))
  if [ "$attempt" -ge 90 ]; then
    log "ERROR: Temporal did not become healthy"
    exit 1
  fi
  sleep 2
done

if temporal operator namespace describe -n "$DEFAULT_NAMESPACE" --address "$GRPC_ADDRESS" >/dev/null 2>&1; then
  log "Namespace '$DEFAULT_NAMESPACE' exists"
else
  temporal operator namespace create -n "$DEFAULT_NAMESPACE" --address "$GRPC_ADDRESS"
  log "Namespace '$DEFAULT_NAMESPACE' created"
fi

log "Ready on port ${FRONTEND_GRPC_PORT:-7233} (gRPC) and $FRONTEND_HTTP_PORT (HTTP)"
wait "$server_pid"
