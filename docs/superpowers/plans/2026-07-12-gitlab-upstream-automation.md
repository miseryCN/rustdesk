# GitLab 上游同步自动化实现计划

> **面向 AI 代理的工作者：** 必需子技能：使用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 逐任务实现此计划。步骤使用复选框（`- [ ]`）语法来跟踪进度。

**目标：** 让 GitLab 定时检测 RustDesk 官方更新，并由 Codex 在独立同步分支解决冲突、创建 Draft MR，随后运行可用的源码校验。

**架构：** GitLab Schedule 触发 `upstream-sync` job；job 使用专用项目机器人令牌创建 `sync/upstream-*` 分支，并将官方 `master` 合并到当前定制 `master`。合并或兼容校验失败时，job 中的 Codex 以 `gpt-5.6-terra`、`high` 推理强度处理；它只能推送同步分支并通过 Git push option 创建 Draft MR。MR 不会被自动合并或发布。

**技术栈：** GitLab CI、GitLab Runner（`gitlab--duo`）、Codex CLI、POSIX shell、Git push options。

---

### 任务 1：声明安全的 GitLab CI 入口

**文件：**
- 创建：`.gitlab-ci.yml`

- [ ] **步骤 1：限制流水线触发来源**

定义 `workflow: rules`，仅允许 Merge Request、`master` push、手工 Web 与 Schedule 管道；同步 job 仅允许 Schedule 或变量 `UPSTREAM_SYNC=1`。

- [ ] **步骤 2：声明互斥的同步任务**

使用 Runner tag `gitlab--duo`、`resource_group: upstream-sync` 和 `GIT_STRATEGY: fetch`，避免两个定时任务同时重放上游提交。

- [ ] **步骤 3：运行 YAML 校验**

运行：`python3 -c 'import yaml; yaml.safe_load(open(".gitlab-ci.yml")); print("valid")'`

预期：输出 `valid`。

### 任务 2：实现上游同步与 Codex 交接脚本

**文件：**
- 创建：`.gitlab/ci/sync-upstream.sh`
- 创建：`.gitlab/ci/codex-upstream-sync.md`

- [ ] **步骤 1：实现无更新退出与同步分支命名**

脚本读取 `UPSTREAM_REPOSITORY_URL`，获取 `master`，在已包含上游 SHA 时安全退出；否则从当前 `master` 创建 `sync/upstream-<short-sha>`。

- [ ] **步骤 2：将冲突处理委托给 Codex**

以 `codex exec --model gpt-5.6-terra` 运行版本受控提示词，明确要求保留服务器配置档功能、执行可用检查、不得操作 `master` 或发布 Release。

- [ ] **步骤 3：创建 Draft MR**

通过专用机器人令牌推送同步分支，并传递 `merge_request.create`、`merge_request.target=master` 与 `Draft:` 标题 push option；不执行 merge。

- [ ] **步骤 4：验证脚本语法**

运行：`bash -n .gitlab/ci/sync-upstream.sh`

预期：退出码 0。

### 任务 3：配置 GitLab 权限与运行时变量

**文件：**
- 修改：GitLab 项目 `xiaoweigod/rustdesk` 设置（非仓库文件）

- [ ] **步骤 1：创建最小权限同步机器人**

创建 Project Access Token，角色为 Developer，scope 为 `api` 与 `write_repository`，365 天后到期；将令牌写为受保护且掩码的项目变量 `UPSTREAM_SYNC_TOKEN`。

- [ ] **步骤 2：保护 `master`**

仅允许 Maintainer 推送和合并 `master`；同步机器人只能创建 `sync/*`，所以 Codex 无法直接覆盖发布线。

- [ ] **步骤 3：设置 Codex 参数**

添加受保护变量 `CODEX_MODEL=gpt-5.6-terra`、`CODEX_REASONING_EFFORT=high`；仅 Schedule 与 `master` 手工管道可读取。

### 任务 4：建立首个同步计划并验证边界

**文件：**
- 修改：GitLab 项目 `xiaoweigod/rustdesk` 的 Pipeline Schedule（非仓库文件）

- [ ] **步骤 1：创建每日计划**

创建每日 02:30（Asia/Shanghai）的 Schedule，ref 为 `master`，变量 `UPSTREAM_SYNC=1`。

- [ ] **步骤 2：验证静态边界**

确认 GitLab 数据库中存在 `codex娘` 的 `gpt-5.6-terra`/`high` 定义、同步机器人变量为 masked/protected、`master` 已保护。

- [ ] **步骤 3：不自动执行首个 AI 同步**

首个 Schedule 仅在下一个周期运行；避免在未配置 macOS/Windows 原生构建与签名环境时自动发版。发布仍要求人工审批。
