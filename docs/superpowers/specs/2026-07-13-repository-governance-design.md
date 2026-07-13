# 仓库治理设计

## 目标

以 GitLab 为唯一开发主库；GitHub 只保存 GitLab `master` 与发布标签的镜像，并继续作为部署拉取来源。

## 分支职责

- `master`：GitLab 受保护主线；只通过 Merge Request 合并。
- `feature/*`：开发分支；必须从 GitLab `master` 创建并通过 Merge Request 合并。
- `sync/upstream-*`：定时同步任务的临时分支；合并或关闭后删除。
- `release/*`：仅在需要冻结发布时创建；常规发布优先使用标签。

官方 RustDesk 仓库只作为 `upstream` 获取来源，不承载本项目提交。

## 镜像数据流

```text
官方 upstream/master -> GitLab sync/upstream-* -> GitLab master -> GitHub master -> 部署
本地与其他客户端 -> GitLab feature/* -> Merge Request -> GitLab master
GitLab 标签 -> GitHub 同名标签 -> 部署或发布
```

GitHub `master` 只允许 GitLab 镜像任务快进推送；镜像脚本不使用强制推送，GitHub 出现人工提交时任务失败并告警，避免覆盖代码。

## 凭据与安全

GitHub 镜像凭据以 GitLab 项目级、隐藏且掩码的 CI/CD 变量保存。GitHub token 以 Base64 编码保存，脚本仅在运行内存中解码。变量只提供给 `master` 与标签流水线。镜像脚本禁止输出令牌。

## 验证与回滚

镜像任务在推送前验证当前分支或标签引用；推送后比较 GitHub 远端 SHA 与当前 SHA。失败不会影响 GitLab `master`。如需停止镜像，禁用该 CI 变量或任务即可；GitHub 不会被强制回退。
