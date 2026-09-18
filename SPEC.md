---
id: specrail
type: goal-and-requirements
status: active
title: specrail — 跨助手规格 CLI
covers: [positioning, v1-scope, architecture, command-surface, exit-codes, distribution, data-format, invariants, porting-map, licensing, verification]
tags: [cli, spec-graph, workflow-skills]
---

## 定位

specrail 是一个跨助手（cross-assistant）的规格工程 CLI：

- 在任意仓库中维护**类型化规格图**——Markdown 文件 + YAML frontmatter，节点以非空标量 `id` + `type` 入图；
- 向编码助手分发工作流技能与命令（Qoder / Claude Code / Codex / pi），由助手执行工作流。

specrail 不内置模型与执行引擎；它只提供确定性操作（图读写、校验、文件分发）。

模型移植自 ThinkRail 的 `packages/spec-graph`（core 为 pi-free 的解析 / 索引 / 查询 / 校验层），
工作流技能移植自 `packages/pi-thinkrail-workflow`（技能文本 + 收窄后的路由规则）。CLI 机制参考
OpenSpec（init / sync 按助手分发、生成物清单治理），但**不兼容其产物格式**。

## V1 范围

**包含**

- 图查询：`list` / `show` / `grep` / `graph`
- 图写入：`create` / `update` / `delete`
- 校验：`validate`（悬空链接 / 重复 id / parent 环）
- 分发：`init` / `sync`，向所选助手生成技能与命令，`.specrail/config.json` 清单治理
- 路由规则：`init --rule` 以标记块写入 AGENTS.md，只改块内
- 技能内容：9 个工作流技能 + 1 个规格图技能（目录名统一前缀 `specrail-`）；系统文档
  `skills/SPEC.md` 说明角色与 meta-rules，随仓库保留、不随 init 分发。

**排除**（V1 明确不做）

- OpenSpec 产物格式兼容（Requirement/Scenario、change/delta、archive 语义）
- 模型执行 / 工作流引擎 / 编排运行时
- store / git 仓库管理、遥测

## 架构

目录即模块；每个模块一个 SPEC.md；依赖方向向下。

```
src/core/        规格图核心（移植自 ThinkRail packages/spec-graph/core）
src/cli/         命令层：参数解析（node:util parseArgs）、输出、退出码
src/distribute/  助手适配器 + init/sync 编排 + 清单治理（命令模板与规则块文本为模块内常量）
skills/          10 个技能 + 系统文档 SPEC.md（英文，分发的源真相）
```

边界：

- **core**：pi-free、Node 兼容（Node ≥ 20.19）；不依赖其它模块；不做参数解析、不写 stdout、不调 exit。
- **cli**：依赖 core；不直接生成助手文件，分发委托 distribute。
- **distribute**：只做文件生成与清单治理，不依赖 core；输入是 skills/，命令模板与 AGENTS.md 规则块为模块内内联常量。

## 命令面

全局参数：`--root <dir>`（默认 cwd）、`-v/--version`、`-h/--help`；查询类支持 `--json`。

| 命令 | 说明 |
|---|---|
| `specrail init [--tools qoder,claude,codex,pi] [--rule]` | 分发技能/命令；`--rule` 追加 AGENTS.md 托管规则块 |
| `specrail sync` | 按清单刷新生成物，清理不再选的助手产物 |
| `specrail list [--type T] [--tag T] [--json]` | 节点清单 |
| `specrail show <id> [--json]` | 节点详情（frontmatter、links、reverseLinks） |
| `specrail grep <pattern> [--regex] [--ignore-case] [--type T] [--tag T] [--parent ID] [--depends-on ID] [--limit N] [--json]` | 全文（含元数据）搜索 |
| `specrail graph <id> [--direction subtree\|ancestors\|neighbors] [--depth N] [--edge KIND] [--json]` | 子树 / 祖先 / 邻接 |
| `specrail create <path> --id I --type T --title S [--status S] [--parent I] [--depends-on I]... [--references I]... [--implements I]... [--covers S]... [--tags S]...` | 创建节点 |
| `specrail update <id> [--set K=V]... [--remove K]... [--add-list K=V]... [--remove-list K=V]...` | 仅重写 frontmatter（保真） |
| `specrail delete <id> [--yes]` | 删除文件，不修引用 |
| `specrail validate [--json]` | 图校验（只报告，不修复） |

## 退出码契约

| 码 | 含义 |
|---|---|
| 0 | 成功（`validate` 无发现也是 0） |
| 1 | `validate` 发现图问题 |
| 2 | 用法 / 执行错误（未知命令或参数、id 不存在、路径被拒、IO 失败） |

执行失败、校验失败、成功三者分离；不得仅以“正常返回”判成功。

## 分发设计

适配器（助手 → 生成物）。已对照 OpenSpec 1.12.0 适配器源码与本机助手安装布局核实，逐项结论与依据见 `src/distribute/SPEC.md`：

| 助手 | 命令 | 技能 |
|---|---|---|
| pi | `.pi/prompts/specrail-<id>.md`（frontmatter 仅 `description`，参数注入 `$@`） | `.pi/skills/specrail-<name>/SKILL.md` |
| Qoder | `.qoder/commands/specrail/<id>.md`（`name`/`description`/`category`/`tags`） | `.qoder/skills/specrail-<name>/SKILL.md` |
| Claude Code | `.claude/commands/specrail/<id>.md`（`name`/`description`/`allowed-tools`/`category`/`tags`，参数注入 `$ARGUMENTS`） | `.claude/skills/specrail-<name>/SKILL.md` |
| Codex | 无命令面（技能即入口；skills-only 为核实结论） | `.agents/skills/specrail-<name>/SKILL.md` |

- `.specrail/config.json`：所选助手、生成文件清单、specrail 版本；`sync` 据此刷新与清理；只动自己生成的。
- `.specrail/.gitignore`（内容 `context/`）：init/sync 始终生成，落实技能内容声称的“`.specrail/context/` 临时文档零 git 足迹”。
- `--rule`：AGENTS.md 托管块 `<!-- specrail:rule:begin -->` … `<!-- specrail:rule:end -->`，块外永不触碰；块存在后 `sync` 亦会刷新块内。
- 路由规则内容 = 收窄后的版本（新项目接入、PR 生命周期必路由；产品/设计未定时进入；已路由任务继续），
  不移植旧版“所有任务先路由”。

## 数据格式（沿用 spec-graph）

- 节点 = 任意 `.md` 文件 + 非空标量 `id` + `type`（title/status 非入图必需）。
- 字段：`id` / `type` / `status` / `title` / `parent`（单链）/ `depends-on` / `references` / `implements`（列表）/ `covers` / `tags`（元数据）。
- type 枚举：`goal-and-requirements` | `architecture-design` | `module-design` | `submodule-design` | `task-spec`。
- status 枚举：`draft` | `active` | `stale` | `done` | `deprecated`。
- 扫描：递归 `.md`，忽略 `node_modules` / `.git` / `dist` / `build`；不遵循 `.gitignore`、不跟随符号链接。

## 不变量（移植携带）

- **保真编辑**：`update` 只重写 frontmatter；未触及字段、注释、嵌套值、字段顺序及正文原字节不变。
- **路径安全**：`create` 仅接受根内相对 `.md` 路径；逐段校正磁盘拼写（大小写），拒绝符号链接与忽略目录变体。
- **校验如实**：仅悬空链接 / 重复 id / parent 环——不是完整 schema 或任意 DAG 校验。
- **创建纪律**：拒绝重复路径与重复 id；回读确认可入图后写入。

## 移植映射

| 来源 | 去向 | 方式 |
|---|---|---|
| `packages/spec-graph/core/*` | `src/core/` | 复制 + 去除宿主耦合 + Node 兼容化（测试随迁） |
| `packages/spec-graph/tools/*`（7 工具） | `src/cli/` | 重写：参数校验、`--json`、退出码 |
| `packages/pi-thinkrail-workflow/skills/*`（9） | `skills/` | 去 pi 化改写（工具引用、硬编码守卫） |
| `packages/spec-graph/skills/*`（1） | `skills/specrail-spec-graph/` | 改写为命令引用 |
| `index.ts` 路由规则 | `src/distribute/rule.ts`（`RULE_TEXT` 常量）+ `init --rule` | 改写为收窄后的托管块 |
| OpenSpec 1.12.0 | 仅机制参考 | init/sync/清单/适配器形态 |

## 许可与归属

Apache-2.0（派生自 ThinkRail，版权 JetBrains s.r.o.）。`NOTICE` 声明来源与修改；不使用 ThinkRail 商标。

## 验证

- **core**：随迁的 bun:test；Node 兼容性以构建产物在 node 下的冒烟守护（`tests/dist.test.ts`：--version / list --json / 退出码）。
- **cli**：临时 fixture 仓库做 create → show → update → validate 往返 + 退出码断言。
- **distribute**：init/sync 后断言文件树、清单治理（含移除助手后的清理）、规则块标记保真。
- **诚实边界**：助手端“实际加载技能”只能人工抽查，不自动化。
- **门禁**：`bun run typecheck` + `bun run lint` + `bun run test`；`tests/dist.test.ts` 先 `bun run build` 再以 node 冒烟 `dist/cli.js`，全新克隆无前置构建步骤。
