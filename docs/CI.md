# GitHub Actions

The workflow is prepared at [`.github/workflow-templates/source-checks.yml`](../.github/workflow-templates/source-checks.yml). It is a template and does **not** run automatically in this location. It checks localization coverage, public source layout, protocol/stop-release behavior, whitespace and committed-history credentials. It has read-only repository permissions, pinned tool versions and a checked download digest.

To activate it, use a GitHub identity allowed to write workflows and move/copy it into `.github/workflows/source-checks.yml`, then commit and push. GitHub CLI OAuth authentication needs the additional `workflow` scope for this path. Repository-content access alone is insufficient. An account owner may grant that scope interactively with `gh auth refresh -s workflow`; no token should be pasted into a file or issue.

Signed iPhone tests and Apple developer-image preparation remain local checks documented in [setup](SETUP.md). CI success does not establish complete app-task acceptance.

模板尚未自动启用。具有工作流写入权限的账号将其放到 `.github/workflows/` 后，提交推送即可运行。GitHub CLI 的普通仓库权限不包含该能力，需要账号所有者交互授予 `workflow` 权限；不要在文件或 issue 中填写令牌。真机签名与开发者镜像准备仍由本地完成。
