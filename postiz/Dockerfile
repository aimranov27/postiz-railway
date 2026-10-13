# Postiz for Railway.
#
# The official image runs nginx (public port), the backend (3000), the
# frontend (4200) and the Temporal workers (orchestrator) under pm2. This
# image adds a startup wrapper that makes it work well on Railway. See
# railway-entrypoint.sh for what it does.
#
# The version is pinned so every deploy is reproducible. The update workflow
# (.github/workflows/update.yml) bumps it after a smoke test.
ARG POSTIZ_VERSION=v2.25.1

FROM ghcr.io/gitroomhq/postiz-app:${POSTIZ_VERSION}

COPY --chmod=755 railway-entrypoint.sh /usr/local/bin/railway-entrypoint.sh
COPY railway-helper.cjs /app/railway/railway-helper.cjs

ENV PORT=8080 \
    UPLOAD_DIRECTORY=/uploads \
    NEXT_PUBLIC_UPLOAD_DIRECTORY=/uploads \
    STORAGE_PROVIDER=local \
    BACKEND_INTERNAL_URL=http://localhost:3000 \
    IS_GENERAL=true \
    NX_ADD_PLUGINS=false

EXPOSE 8080
ENTRYPOINT ["railway-entrypoint.sh"]
CMD []
