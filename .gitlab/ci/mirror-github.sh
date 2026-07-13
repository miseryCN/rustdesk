#!/usr/bin/env bash

set -Eeuo pipefail

readonly mirror_repository="${GITHUB_MIRROR_REPOSITORY:-miseryCN/rustdesk}"
readonly mirror_branch="${GITHUB_MIRROR_BRANCH:-master}"

require_variable() {
  local variable_name="$1"
  if [[ -z "${!variable_name:-}" ]]; then
    printf 'Missing required CI/CD variable: %s\n' "$variable_name" >&2
    exit 1
  fi
}

require_variable GITHUB_MIRROR_USERNAME
require_variable GITHUB_MIRROR_TOKEN_B64

GITHUB_MIRROR_TOKEN="$(printf '%s' "$GITHUB_MIRROR_TOKEN_B64" | base64 --decode)"
if [[ -z "$GITHUB_MIRROR_TOKEN" ]]; then
  printf 'GITHUB_MIRROR_TOKEN_B64 decoded to an empty token.\n' >&2
  exit 1
fi

if [[ -n "${CI_COMMIT_TAG:-}" ]]; then
  source_ref="refs/tags/${CI_COMMIT_TAG}"
  target_ref="$source_ref"
  expected_sha="$CI_COMMIT_SHA"
  verification_ref="${source_ref}^{}"
  fallback_verification_ref="$source_ref"
elif [[ "${CI_COMMIT_BRANCH:-}" == "master" ]]; then
  source_ref="$CI_COMMIT_SHA"
  target_ref="refs/heads/${mirror_branch}"
  expected_sha="$CI_COMMIT_SHA"
  verification_ref="$target_ref"
  fallback_verification_ref=""
else
  printf 'GitHub mirror only accepts master or tag pipelines.\n' >&2
  exit 1
fi

mirror_url="https://${GITHUB_MIRROR_USERNAME}:${GITHUB_MIRROR_TOKEN}@github.com/${mirror_repository}.git"

# Do not use --force: an unexpected GitHub commit must stop the pipeline.
git push "$mirror_url" "${source_ref}:${target_ref}"

actual_sha="$(git ls-remote "$mirror_url" "$verification_ref" | awk -v ref="$verification_ref" '$2 == ref { print $1; exit }')"
if [[ -z "$actual_sha" && -n "$fallback_verification_ref" ]]; then
  actual_sha="$(git ls-remote "$mirror_url" "$fallback_verification_ref" | awk -v ref="$fallback_verification_ref" '$2 == ref { print $1; exit }')"
fi

if [[ "$actual_sha" != "$expected_sha" ]]; then
  printf 'GitHub mirror verification failed: expected %s, got %s.\n' "$expected_sha" "${actual_sha:-missing}" >&2
  exit 1
fi

printf 'GitHub mirror verified: %s -> %s (%s)\n' "$source_ref" "$target_ref" "$expected_sha"
