#!/usr/bin/env bash
# Attaches files to the Tangled tag being built. Runs in a Tangled workflow on a tag push
# (.tangled/workflows/release-*.yml):
#
#   scripts/publish-tangled.sh dist/atdrive-0.2.0-linux-x86_64.tar.gz ...
#
# Each file is uploaded to the repository's knot as a blob, then an org.tangled.repo.artifact
# record points the tag's commit at it, which lists it on the tag's page. This follows Tangled's
# "release artifact on tag" example (https://tangled.org/docs/spindles/writing-workflows/).
#
# Needs goat, curl and jq, and these pipeline secrets (Settings → Pipelines → Secrets):
#   RELEASE_HANDLE         the handle of the repository's owner (or a collaborator)
#   RELEASE_APP_PASSWORD   an app password for that account
# Tangled sets TANGLED_REPO_KNOT and TANGLED_REPO_REPO_DID; HEAD is the tag's commit.
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { echo "error: $*" >&2; exit 1; }

[[ $# -gt 0 ]] || fail "usage: scripts/publish-tangled.sh <file>..."
for var in RELEASE_HANDLE RELEASE_APP_PASSWORD; do
  [[ -n "${!var:-}" ]] || fail "$var isn't set: add it under the repository's Settings → Pipelines → Secrets."
done
for var in TANGLED_REPO_KNOT TANGLED_REPO_REPO_DID; do
  [[ -n "${!var:-}" ]] || fail "$var isn't set: run this in a Tangled workflow."
done
for tool in goat curl jq; do
  command -v "$tool" >/dev/null || fail "needs $tool."
done

# Tangled's limit for one artifact.
LIMIT=$((50 * 1024 * 1024))
for file in "$@"; do
  [[ -f "$file" ]] || fail "no such file: $file"
  size=$(wc -c < "$file")
  ((size <= LIMIT)) || fail "$file is $((size / 1024 / 1024)) MiB: Tangled takes up to 50 MiB per file."
done

goat account login -u "$RELEASE_HANDLE" -p "$RELEASE_APP_PASSWORD"
xrpc="https://$TANGLED_REPO_KNOT/xrpc"
# Each write to the knot needs a new token, for that one method.
token() { goat account service-auth --aud "$TANGLED_REPO_REPO_DID" --lxm "$1"; }
oid=$(git rev-parse HEAD)

for file in "$@"; do
  name=$(basename "$file")
  case "$name" in
    *.tar.gz) type=application/gzip ;;
    *.zip) type=application/zip ;;
    *.sha256) type=text/plain ;;
    *) type=application/octet-stream ;;
  esac

  blob=$(curl -fsS "$xrpc/com.atproto.repo.uploadBlob" \
    -H "Authorization: Bearer $(token com.atproto.repo.uploadBlob)" \
    -H "Content-Type: $type" \
    --data-binary "@$file" | jq -c .blob)

  jq -n \
    --arg repo "$TANGLED_REPO_REPO_DID" \
    --arg oid "$oid" \
    --arg name "$name" \
    --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson blob "$blob" \
    '{
      repo: $repo,
      collection: "org.tangled.repo.artifact",
      record: {
        "$type": "org.tangled.repo.artifact",
        subject: { "$type": "org.tangled.git.oid", oid: $oid },
        name: $name,
        createdAt: $now,
        artifact: $blob
      }
    }' |
    curl -fsS "$xrpc/com.atproto.repo.createRecord" \
      -H "Authorization: Bearer $(token com.atproto.repo.createRecord)" \
      -H "Content-Type: application/json" \
      --data-binary @- >/dev/null

  echo "Attached $name"
done
