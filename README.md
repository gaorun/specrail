# specrail

跨助手规格 CLI：在仓库中维护类型化规格图，并向编码助手（Qoder / Claude Code / Codex / pi）分发工作流技能与命令。

- 规格图：Markdown + YAML frontmatter，节点以非空 `id` + `type` 入图；
- 工作流：技能与命令由助手执行，specrail 不内置模型与执行引擎；
- 派生说明与许可见 `SPEC.md`、`NOTICE`、`LICENSE`。

## 快速开始

```sh
bun install
bun run build

# 在目标仓库中初始化并选择助手（--rule 追加 AGENTS.md 托管规则块）
node dist/cli.js init --tools qoder,claude --rule

# 查询与维护规格图
node dist/cli.js list
node dist/cli.js show specrail
node dist/cli.js validate
```

## init / sync 生成什么

- `skills/` 下的技能按助手落位（如 `.qoder/skills/specrail-<name>/SKILL.md`、`.pi/prompts/specrail-<name>.md`），
  逐字节复制，不做内容改写；技能源以本仓库为准；
- `.specrail/config.json` 记录所选助手与生成文件清单；`specrail sync` 按清单刷新内容，并清理不再选择的助手产物——
  只动清单记录过的文件，用户自建文件永不触碰；
- `.specrail/.gitignore`（`context/`）保证技能工作流使用的临时文档不进入 git；
- `--rule`（或此后任意一次 `sync`）维护 AGENTS.md 中的 `specrail:rule` 托管块，块外内容不动。

## 命令面

`init` `sync` `list` `show` `grep` `graph` `create` `update` `delete` `validate`
（`--help` 查看参数；退出码：0 成功、1 validate 发现问题、2 用法/执行错误。）

## 开发

```sh
bun run typecheck
bun run lint
bun run test        # 含 dist 冒烟（自动先构建）
```
