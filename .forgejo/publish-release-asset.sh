#!/usr/bin/env bash
# Publish one asset to a Forgejo release, creating the release if it doesn't
# exist yet. Idempotent: safe to call from both build jobs and across re-runs.
#
# We own the publish via the direct Forgejo API (curl + jq) instead of the
# forgejo-release action — see Forgejo-Actions.md Appendix B for why.
#
# Usage: publish-release-asset.sh <asset-file>
# Env:
#   SERVER      instance URL, e.g. https://git.paths.place  (github.server_url)
#   REPO        owner/repo                                   (github.repository)
#   TOKEN       run token                                    (github.token)
#   TAG         release tag (inputs.version)
#   TARGET_SHA  commit to tag                                (github.sha)
#   REL_NAME    release title
#   REL_BODY    release notes
#   PRERELEASE  "true" | "false"
set -euo pipefail

asset="$1"
api="$SERVER/api/v1/repos/$REPO"
auth="Authorization: token $TOKEN"

# 1. Ensure the release exists. POST returns 201 the first time; on any re-run
#    (or from the second build job) it's non-201, so fall back to GET-by-tag.
req=$(jq -n \
  --arg tag "$TAG" --arg sha "$TARGET_SHA" --arg name "$REL_NAME" \
  --arg notes "$REL_BODY" --argjson pre "${PRERELEASE:-false}" \
  '{tag_name:$tag, target_commitish:$sha, name:$name, body:$notes, draft:false, prerelease:$pre}')

code=$(curl -sS -o /tmp/rel.json -w '%{http_code}' \
  -X POST "$api/releases" -H "$auth" -H 'Content-Type: application/json' -d "$req")

if [ "$code" = "201" ]; then
  echo "Created release $TAG"
else
  echo "POST /releases returned $code; fetching existing release for tag $TAG"
  curl -sS -o /tmp/rel.json "$api/releases/tags/$TAG" -H "$auth"
fi

rel_id=$(jq -r '.id // empty' /tmp/rel.json)
[ -n "$rel_id" ] || { echo "Could not resolve release id:"; cat /tmp/rel.json; exit 1; }

# 2. Upload the asset. Delete a same-named asset first so re-runs don't 409.
name=$(basename "$asset")
enc=$(jq -rn --arg n "$name" '$n|@uri')   # URL-encode (handles spaces etc.)

old=$(curl -sS "$api/releases/$rel_id/assets" -H "$auth" \
        | jq -r --arg n "$name" '.[] | select(.name==$n) | .id')
if [ -n "$old" ]; then
  echo "Replacing existing asset $name (id $old)"
  curl -sS -X DELETE "$api/releases/$rel_id/assets/$old" -H "$auth" >/dev/null
fi

code=$(curl -sS -o /tmp/asset.json -w '%{http_code}' \
  -X POST "$api/releases/$rel_id/assets?name=$enc" -H "$auth" -F "attachment=@$asset")
[ "$code" = "201" ] || { echo "Asset upload failed ($code):"; cat /tmp/asset.json; exit 1; }
echo "Uploaded $name"
