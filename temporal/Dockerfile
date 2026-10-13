# Temporal server for Postiz on Railway.
#
# Postiz runs its scheduling and publishing workers on Temporal. This image is
# the official Temporal server plus the schema tool and CLI from the matching
# admin-tools image, so a single service can create its databases, migrate
# them and create the namespace on every boot. It replaces the deprecated
# temporalio/auto-setup image that Postiz's own docker-compose still uses.
#
# Versions are pinned so every deploy is reproducible. The update workflow
# (.github/workflows/update.yml) bumps them after a smoke test.
ARG TEMPORAL_VERSION=1.32.1

FROM temporalio/admin-tools:${TEMPORAL_VERSION} AS admin-tools

FROM temporalio/server:${TEMPORAL_VERSION}

COPY --from=admin-tools --chmod=755 /usr/local/bin/temporal-sql-tool /usr/local/bin/temporal /usr/local/bin/
COPY --from=admin-tools /etc/temporal/schema /etc/temporal/schema
COPY dynamicconfig.yaml /etc/temporal/config/dynamicconfig/postiz.yaml
COPY --chmod=755 docker-entrypoint.sh /etc/temporal/railway-entrypoint.sh

# Postgres (shared with Postiz) stores both the main and the visibility data,
# so no Elasticsearch is needed.
ENV DB=postgres12 \
    DBNAME=temporal \
    VISIBILITY_DBNAME=temporal_visibility \
    DEFAULT_NAMESPACE=default \
    DYNAMIC_CONFIG_FILE_PATH=/etc/temporal/config/dynamicconfig/postiz.yaml \
    SQL_MAX_CONNS=10 \
    SQL_MAX_IDLE_CONNS=10 \
    SQL_VIS_MAX_CONNS=5 \
    SQL_VIS_MAX_IDLE_CONNS=5

CMD ["/etc/temporal/railway-entrypoint.sh"]
