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

fetch_upstream_ref_with_retry() {
  local remote="$1"
  local refspec="$2"
  local max_attempts="${UPSTREAM_FETCH_ATTEMPTS:-3}"
  local retry_delay="${UPSTREAM_FETCH_RETRY_DELAY_SECONDS:-5}"
  local attempt=1

  while true; do
    if git -c fetch.recurseSubmodules=false fetch --no-tags "$remote" "$refspec"; then
      return 0
    fi

    if (( attempt >= max_attempts )); then
      printf 'Failed to fetch %s from %s after %s attempts.\n' \
        "$refspec" "$remote" "$attempt" >&2
      return 1
    fi

    printf 'Fetch attempt %s/%s failed; retrying in %ss.\n' \
      "$attempt" "$max_attempts" "$retry_delay" >&2
    sleep "$retry_delay"
    ((attempt++))
  done
}

sync_merge_request_iids_from_json() {
  local merge_requests="$1"
  printf '%s\n' "$merge_requests" \
    | sed 's/},{"id":/}\n{"id":/g' \
    | while IFS= read -r merge_request; do
        case "$merge_request" in
          *'"source_branch":"sync/upstream-'*)
            printf '%s\n' "$merge_request" \
              | sed -n 's/.*"iid":\([0-9][0-9]*\).*/\1/p'
            ;;
        esac
      done
}

close_superseded_sync_merge_requests() {
  local sync_branch="$1"
  local endpoint="${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/merge_requests"
  local merge_requests current_iid stale_iid

  merge_requests="$(curl --fail --silent --show-error \
    --header "PRIVATE-TOKEN: ${UPSTREAM_SYNC_TOKEN}" \
    "${endpoint}?state=opened&target_branch=${target_branch}&per_page=100")"
  current_iid="$(printf '%s\n' "$merge_requests" \
    | sed 's/},{"id":/}\n{"id":/g' \
    | while IFS= read -r merge_request; do
        case "$merge_request" in
          *"\"source_branch\":\"${sync_branch}\""*)
            printf '%s\n' "$merge_request" \
              | sed -n 's/.*"iid":\([0-9][0-9]*\).*/\1/p'
            ;;
        esac
      done)"

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
  done < <(sync_merge_request_iids_from_json "$merge_requests" \
    | grep -Fxv "$current_iid" || true)
}
