# 仓库治理实现计划

> **面向 AI 代理的工作者：** 必需子技能：使用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 逐任务实现此计划。步骤使用复选框（`- [ ]`）语法来跟踪进度。

**目标：** 使 GitLab `master` 自动、安全地镜像到 GitHub `master`，同时保持 GitHub 为只读部署来源。

**架构：** 在 GitLab 默认分支和标签流水线增加独立的镜像阶段。脚本只推送当前 `master` 或当前标签，拒绝强制推送；GitHub 凭据由隐藏 CI/CD 变量提供。

**技术栈：** GitLab CI、Bash、GitHub HTTPS token。

---

### 任务 1：增加 GitHub 镜像脚本

**文件：**
- 创建：`.gitlab/ci/mirror-github.sh`

- [ ] 校验 `GITHUB_MIRROR_USERNAME` 和 `GITHUB_MIRROR_TOKEN`。
- [ ] 在 `master` 流水线仅快进推送 `master`；在标签流水线仅推送当前标签。
- [ ] 推送后用 `git ls-remote` 验证远端 SHA 与本地 SHA 一致。

### 任务 2：接入 GitLab CI

**文件：**
- 修改：`.gitlab-ci.yml`

- [ ] 新增 `mirror` stage，位于 `verify` 后。
- [ ] 仅在 `master` 或标签流水线运行镜像任务。
- [ ] 保留现有上游同步和 MR 验证规则。

### 任务 3：配置、首次同步与验证

**配置：**
- GitLab 项目 21：`GITHUB_MIRROR_USERNAME`、`GITHUB_MIRROR_TOKEN_B64`。

- [ ] 将变量设为隐藏、掩码，且只允许受保护分支和标签使用。
- [ ] 将 GitLab `master` 快进同步到 GitHub `master`。
- [ ] 验证两端 `master` SHA 相同；确认 GitLab 未来流水线能够在不使用强制推送的前提下镜像。
- [ ] 仅在验证完成后清理已合并的 `sync/upstream-*` 临时分支。
