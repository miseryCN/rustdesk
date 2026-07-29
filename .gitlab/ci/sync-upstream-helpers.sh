#!/usr/bin/env bash

sync_branch_name() {
  local upstream_sha="$1"
  local pipeline_id="$2"
  printf 'sync/upstream-%s-%s\n' "${upstream_sha:0:12}" "$pipeline_id"
}

verify_submodules_are_fetchable() {
  git submodule sync --recursive
  git submodule update --init --recursive
}

close_superseded_sync_merge_requests() {
  local sync_branch="$1"
  local endpoint="${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/merge_requests"
  local merge_requests current_iid stale_iid

  merge_requests="$(curl --fail --silent --show-error \
    --header "PRIVATE-TOKEN: ${UPSTREAM_SYNC_TOKEN}" \
    "${endpoint}?state=opened&target_branch=${target_branch}&per_page=100")"
  current_iid="$(jq -r --arg branch "$sync_branch" \
    '.[] | select(.source_branch == $branch) | .iid' <<<"$merge_requests")"

  if [[ -z "$current_iid" ]]; then
    printf 'Could not find the Merge Request for %s after push.\n' "$sync_branch" >&2
    return 1
  fi

  while IFS= read -r stale_iid; do
    [[ -z "$stale_iid" ]] && continue
    curl --fail --silent --show-error \
      --request PUT \
      --header "PRIVATE-TOKEN: ${UPSTREAM_SYNC_TOKEN}" \
      --data-urlencode 'state_event=close' \
      "${endpoint}/${stale_iid}" >/dev/null
    printf 'Closed superseded upstream sync MR !%s.\n' "$stale_iid"
  done < <(jq -r --arg current_iid "$current_iid" '
    .[]
    | select(.source_branch | startswith("sync/upstream-"))
    | select((.iid | tostring) != $current_iid)
    | .iid
  ' <<<"$merge_requests")
}
