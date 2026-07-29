#!/usr/bin/env bash

set -Eeuo pipefail

readonly script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$script_dir/.gitlab/ci/sync-upstream-helpers.sh"

assert_eq() {
  local expected="$1"
  local actual="$2"
  local message="$3"
  if [[ "$actual" != "$expected" ]]; then
    printf 'FAIL: %s\nexpected: %s\nactual: %s\n' "$message" "$expected" "$actual" >&2
    exit 1
  fi
}

test_sync_branch_name_uses_pipeline_id() {
  assert_eq \
    'sync/upstream-0123456789ab-101' \
    "$(sync_branch_name 0123456789abcdef 101)" \
    'sync branch must include the pipeline ID'
}

test_submodule_validation_stops_on_unavailable_commit() {
  local fake_bin
  fake_bin="$(mktemp -d)"
  trap 'rm -rf "$fake_bin"' RETURN
  cat >"$fake_bin/git" <<'EOF'
#!/usr/bin/env bash
if [[ "$1 $2 $3" == 'submodule sync --recursive' ]]; then
  exit 0
fi
if [[ "$1 $2 $3" == 'submodule update --init' ]]; then
  exit 1
fi
printf 'unexpected git command: %s\n' "$*" >&2
exit 2
EOF
  chmod +x "$fake_bin/git"

  if PATH="$fake_bin:$PATH" verify_submodules_are_fetchable; then
    printf 'FAIL: unavailable submodule commit was accepted\n' >&2
    exit 1
  fi
}

test_sync_mr_parser_needs_no_jq() {
  local merge_requests
  merge_requests='[{"id":10,"iid":4,"source_branch":"sync/upstream-old-1"},{"id":11,"iid":5,"source_branch":"fix/other"},{"id":12,"iid":6,"source_branch":"sync/upstream-new-2"}]'

  assert_eq \
    $'4\n6' \
    "$(sync_merge_request_iids_from_json "$merge_requests")" \
    'only upstream sync MRs should be selected without jq'
}

test_upstream_fetch_retries_transient_failure() {
  local fake_bin attempts_file
  fake_bin="$(mktemp -d)"
  attempts_file="$fake_bin/attempts"
  trap 'rm -rf "$fake_bin"' RETURN
  cat >"$fake_bin/git" <<EOF
#!/usr/bin/env bash
attempts_file="$attempts_file"
attempts=0
[[ -f "\$attempts_file" ]] && attempts="\$(cat "\$attempts_file")"
attempts=\$((attempts + 1))
printf '%s' "\$attempts" >"\$attempts_file"
[[ "\$attempts" -ge 2 ]]
EOF
  chmod +x "$fake_bin/git"

  PATH="$fake_bin:$PATH" UPSTREAM_FETCH_ATTEMPTS=2 UPSTREAM_FETCH_RETRY_DELAY_SECONDS=0 \
    fetch_upstream_ref_with_retry upstream refs/heads/master:refs/remotes/upstream/master
  assert_eq '2' "$(cat "$attempts_file")" 'transient upstream failure should be retried once'
}

test_sync_branch_name_uses_pipeline_id
test_submodule_validation_stops_on_unavailable_commit
test_sync_mr_parser_needs_no_jq
test_upstream_fetch_retries_transient_failure
printf 'sync-upstream helper tests passed\n'
