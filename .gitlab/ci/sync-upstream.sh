#!/usr/bin/env bash

set -Eeuo pipefail

readonly upstream_url="${UPSTREAM_REPOSITORY_URL:-https://github.com/rustdesk/rustdesk.git}"
readonly target_branch="${UPSTREAM_TARGET_BRANCH:-master}"
readonly codex_model="${CODEX_MODEL:-gpt-5.6-terra}"
readonly codex_reasoning_effort="${CODEX_REASONING_EFFORT:-high}"
readonly report_path="upstream-sync-report.md"

require_variable() {
  local variable_name="$1"
  if [[ -z "${!variable_name:-}" ]]; then
    printf 'Missing required CI/CD variable: %s\n' "$variable_name" >&2
    exit 1
  fi
}

require_variable CI_SERVER_HOST
require_variable CI_PROJECT_PATH
require_variable UPSTREAM_SYNC_USERNAME
require_variable UPSTREAM_SYNC_TOKEN

git config user.name "RustDesk upstream sync bot"
git config user.email "rustdesk-upstream-sync@noreply.local"
git remote remove upstream 2>/dev/null || true
git remote add upstream "$upstream_url"
git fetch --no-tags upstream "refs/heads/${target_branch}:refs/remotes/upstream/${target_branch}"
git fetch origin "refs/heads/${target_branch}:refs/remotes/origin/${target_branch}"

base_ref="origin/${target_branch}"
upstream_ref="upstream/${target_branch}"
upstream_sha="$(git rev-parse "$upstream_ref")"
upstream_short_sha="${upstream_sha:0:12}"
sync_branch="sync/upstream-${upstream_short_sha}"

if git merge-base --is-ancestor "$upstream_ref" "$base_ref"; then
  printf '# 上游同步报告\n\n官方提交 `%s` 已包含在 `%s` 中，无需创建 Merge Request。\n' \
    "$upstream_sha" "$target_branch" > "$report_path"
  exit 0
fi

git switch --create "$sync_branch" "$base_ref"
git merge --no-commit --no-ff "$upstream_ref" || true

if ! git diff --name-only --diff-filter=U | grep -q .; then
  git commit --no-edit -m "chore: 同步 RustDesk 上游 ${upstream_short_sha}"
fi

codex exec \
  --ephemeral \
  --sandbox danger-full-access \
  --model "$codex_model" \
  --config "model_reasoning_effort=\"${codex_reasoning_effort}\"" \
  --config 'shell_environment_policy.inherit="core"' \
  --config 'shell_environment_policy.exclude=["*TOKEN*", "*KEY*", "*SECRET*", "CI_*"]' \
  --output-last-message "$report_path" \
  "$(<.gitlab/ci/codex-upstream-sync.md)"

if git diff --name-only --diff-filter=U | grep -q .; then
  printf 'Codex left unresolved merge conflicts.\n' >&2
  exit 1
fi

git diff --check

if [[ -n "$(git status --porcelain)" ]]; then
  git add --all
  git commit -m "fix: 适配 RustDesk 上游 ${upstream_short_sha}"
fi

git remote set-url origin "http://${UPSTREAM_SYNC_USERNAME}:${UPSTREAM_SYNC_TOKEN}@${CI_SERVER_HOST}/${CI_PROJECT_PATH}.git"
git push origin "HEAD:refs/heads/${sync_branch}" \
  -o merge_request.create \
  -o "merge_request.target=${target_branch}" \
  -o "merge_request.title=Draft: 同步 RustDesk 上游 ${upstream_short_sha}" \
  -o "merge_request.description=由定时同步任务创建。请审查 Codex 报告与 CI 结果后再合并。"
