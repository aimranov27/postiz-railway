#!/usr/bin/env bash
# Bumps the pinned versions in postiz/Dockerfile and temporal/Dockerfile.
#
# Postiz is bumped as soon as a GitHub release has its image on GHCR.
# Temporal patch releases are bumped on Mondays, together with a Postiz
# release, or when FORCE_ALL=1. That keeps "update available" notices for
# template users to roughly one a week.
#
# Temporal must be upgraded one minor version at a time (1.32 -> 1.33 ->
# 1.34). Template users apply updates whenever they like and may skip some,
# so a new Temporal minor is never bumped automatically. It is reported in
# $NOTICES_FILE (if set) so the workflow can open an issue for a manual bump.
#
# Prints a markdown summary of changes; prints nothing if nothing changed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
POSTIZ_DOCKERFILE="$ROOT/postiz/Dockerfile"
TEMPORAL_DOCKERFILE="$ROOT/temporal/Dockerfile"

current() { sed -n "s/^ARG $2=//p" "$1"; }
bump() { sed -i.bak "s/^ARG $2=.*/ARG $2=$3/" "$1" && rm -f "$1.bak"; }

ghcr_tag_exists() {
  local token
  token="$(curl -fsS "https://ghcr.io/token?scope=repository:gitroomhq/postiz-app:pull" | jq -r .token)"
  curl -fsS -o /dev/null -H "Authorization: Bearer $token" \
    -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json' \
    "https://ghcr.io/v2/gitroomhq/postiz-app/manifests/$1"
}

dockerhub_tags() {
  curl -fsS "https://hub.docker.com/v2/repositories/$1/tags?page_size=100&ordering=last_updated" \
    | jq -r '.results[].name'
}

latest_postiz() {
  curl -fsS ${GITHUB_TOKEN:+-H "Authorization: Bearer $GITHUB_TOKEN"} \
    https://api.github.com/repos/gitroomhq/postiz-app/releases/latest | jq -r .tag_name
}

changes=""

old="$(current "$POSTIZ_DOCKERFILE" POSTIZ_VERSION)"
new="$(latest_postiz)"
if [ -n "$new" ] && [ "$new" != "null" ] && [ "$old" != "$new" ] && ghcr_tag_exists "$new"; then
  bump "$POSTIZ_DOCKERFILE" POSTIZ_VERSION "$new"
  changes+="- Postiz: \`${old}\` → \`${new}\` ([release notes](https://github.com/gitroomhq/postiz-app/releases/tag/${new}))"$'\n'
fi
postiz_changed="$changes"

if [ -n "$postiz_changed" ] || [ "$(date -u +%u)" = 1 ] || [ "${FORCE_ALL:-}" = 1 ]; then
  old="$(current "$TEMPORAL_DOCKERFILE" TEMPORAL_VERSION)"
  minor="${old%.*}"
  server_tags="$(dockerhub_tags temporalio/server | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V)"
  admin_tags="$(dockerhub_tags temporalio/admin-tools | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V)"
  # Newest patch of the current minor that exists for both images.
  new="$(comm -12 <(echo "$server_tags" | sort) <(echo "$admin_tags" | sort) \
    | grep -F "${minor}." | sort -V | tail -n1)"
  if [ -n "$new" ] && [ "$old" != "$new" ]; then
    bump "$TEMPORAL_DOCKERFILE" TEMPORAL_VERSION "$new"
    changes+="- Temporal: \`${old}\` → \`${new}\` ([release notes](https://github.com/temporalio/temporal/releases/tag/v${new}))"$'\n'
  fi

  next_minor="$(echo "$server_tags" | sort -V | tail -n1)"
  if [ -n "${NOTICES_FILE:-}" ] && [ "${next_minor%.*}" != "$minor" ]; then
    echo "Temporal ${next_minor} is out. The template runs ${minor}.x. Temporal must be upgraded one minor version at a time, so bump TEMPORAL_VERSION in temporal/Dockerfile by hand to the latest patch of the next minor, run the smoke test, and publish." > "$NOTICES_FILE"
  fi
fi

printf '%s' "$changes"
