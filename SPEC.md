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
src/core/        规格图核心：解析 / 图 / 查询 / 校验 / 索引 / 子集正则（.zig）
src/cli/         命令层：参数解析、输出（含精确 JSON）、退出码（.zig）
src/distribute/  助手适配器 + init/sync 编排 + 清单治理（命令模板与规则块文本为模块内常量）
tools/           构建期工具：技能内嵌代码生成、插件装配（.zig，仅构建时运行）
skills/          10 个技能 + 系统文档 SPEC.md（英文，分发的源真相；编译期内嵌于 CLI）
```

边界：

- **core**：pi-free、无第三方依赖（仅 Zig 标准库）；不依赖其它模块；不做参数解析、不写 stdout、不调 exit。
- **cli**：依赖 core；参数解析是内置的 `node:util parseArgs` 兼容层（错误消息逐字对齐）；不直接生成助手文件，分发委托 distribute。
- **distribute**：只做文件生成与清单治理，不依赖 core；输入是技能表（CLI 传入编译期内嵌的技能源；测试注入临时目录），命令模板与 AGENTS.md 规则块为模块内内联常量。

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

### 插件市场分发

Claude Code 与 Qoder 共用技能和原生 CLI，分别提供 `.claude-plugin/`、`.qoder-plugin/` 清单。
市场安装是 init/sync 之外的独立入口，不生成项目助手配置，也不需要再次 init。

`zig build plugin` 交叉编译六个平台（macOS / Windows / Linux 的 x64 与 arm64；Linux 为静态 musl）
并装配 `plugins/specrail/`。单平台约 0.4–0.75 MiB，插件合计约 3.2 MiB。运行不依赖系统 Node、Bun、
Zig、nvm、mise 或 n；不加载项目运行时配置，不修改项目环境。
`bin/` 启动器由助手加入执行环境，保留调用者 cwd、参数和退出码；不支持的平台或不完整产物明确失败，
不下载依赖或回退系统 Node。CLI 版本（`VERSION`）与技能源在构建期固定：技能由 `tools/embed_skills.zig`
校验后编译期内嵌，助手读取的技能随插件复制，二者同源构建。

当前仓库的 Git URL 即市场入口；根市场清单的 source 指向 `./plugins/specrail`。
全平台产物连同二进制、隐藏清单及可执行权限纳入当前仓库 Git 版本，不另建分发仓库。
安装缓存仅包含该子目录，不携带源码仓库构建配置，避免助手在安装时拉取开发依赖。
CLI、技能或版本改变后必须重新构建 `zig build plugin` 并与源码一起提交；`-Dcurrent` / `-Doutdir=`
仅供本机验证，产物不提交。
`runtime.json` 记录 `{runtime: "zig", version: <Zig 工具链版本>, targets: [...]}`；二进制静态包含
Zig 标准库与 compiler-rt（MIT，见 `licenses/zig-MIT.txt` 与 `NOTICE`），不含 Bun 运行时或 JS 依赖。
构建不承担提交、推送或合规认证。

## 数据格式（沿用 spec-graph）

- 节点 = 任意 `.md` 文件 + 非空标量 `id` + `type`（title/status 非入图必需）。
- 字段：`id` / `type` / `status` / `title` / `parent`（单链）/ `depends-on` / `references` / `implements`（列表）/ `covers` / `tags`（元数据）。
- type 枚举：`goal-and-requirements` | `architecture-design` | `module-design` | `submodule-design` | `task-spec`。
- status 枚举：`draft` | `active` | `stale` | `done` | `deprecated`。
- 扫描：递归 `.md`，忽略 `node_modules` / `.git` / `dist` / `build`；不遵循 `.gitignore`、不跟随符号链接。

## 不变量（移植携带）

- **保真编辑**：`update` 只重写 frontmatter；未触及行（含引用风格、块列表、注释、嵌套值、字段顺序）及正文逐字节不变；仅被编辑的键重写为规范形式（列表重写为行内流式；多行值写为 `|-` 块标量）。
- **路径安全**：`create` 仅接受根内相对 `.md` 路径；逐段校正磁盘拼写（大小写），拒绝符号链接与忽略目录变体。
- **校验如实**：仅悬空链接 / 重复 id / parent 环——不是完整 schema 或任意 DAG 校验。
- **创建纪律**：拒绝重复路径与重复 id；回读确认可入图后写入。

## 移植偏差（TS → Zig，契约级）

- 遍历与 `list` 排序为**字节序**（原 NFC 归一化 + 原始名平局 → 记录为偏差；规范化等价命名场景的排序可能与源实现不同）。
- 大小写折叠为 **ASCII 折叠**（原 Unicode `toLowerCase`）；`grep` 与 `resolveSpecPath` 的折叠匹配同理。
- `grep --regex` 为**子集引擎**：不支持 lookaround、反向引用、``、Unicode 属性类；非法模式的错误细节文案不复刻（保留 `Invalid search pattern:` 前缀）。
- `update` 的多行标量写为 `|-` 块标量（源实现输出一种 plain 多行形态）；未触碰行逐字节保留（源实现对全部行做 yaml 库重序列化，但同样保留注释与原始引用）。
- 行为契约由 `test/golden/` 语料钉住：语料由移植前的 TS 实现在本机采集，Zig 端逐字节回放；上表偏差在测试中显式标注。

## 移植映射

| 来源 | 去向 | 方式 |
|---|---|---|
| `packages/spec-graph/core/*` | `src/core/` | 复制 + 去除宿主耦合 + Node 兼容化（测试随迁） |
| `packages/spec-graph/tools/*`（7 工具） | `src/cli/` | 重写：参数校验、`--json`、退出码 |
| `packages/pi-thinkrail-workflow/skills/*`（9） | `skills/` | 去 pi 化改写（工具引用、硬编码守卫） |
| `packages/spec-graph/skills/*`（1） | `skills/specrail-spec-graph/` | 改写为命令引用 |
| `index.ts` 路由规则 | `src/distribute/rule.ts`（`RULE_TEXT` 常量）+ `init --rule` | 改写为收窄后的托管块 |
| OpenSpec 1.12.0 | 仅机制参考 | init/sync/清单/适配器形态 |
| `src/**/*.ts`（本仓库上一实现） | `src/**/*.zig` | 全量重写（2026-09-18）：TS/Bun 实现退役，行为以 `test/golden/` 语料回放验证 |

## 许可与归属

Apache-2.0（派生自 ThinkRail，版权 JetBrains s.r.o.）。`NOTICE` 声明来源与修改；不使用 ThinkRail 商标。
插件二进制静态包含 Zig 标准库与 compiler-rt（MIT，Copyright (c) Zig contributors），见 `licenses/zig-MIT.txt`。

## 验证

- **单元**：`zig build test`——core（解析/序列化/编辑/graph/query/validate/子集正则）、cli（参数解析消息表）、distribute（适配器渲染、清单校验、规则块、技能源校验、init/删工具清理）。
- **契约回放**：`zig build test-e2e`——用移植前 TS 实现采集的 golden 语料（`test/golden/`）逐字节驱动真实二进制：全部读/写命令的文本与 `--json` 输出、退出码、错误消息、init 生成树（93 文件逐字节）；`sync` 幂等复验。
- **插件**：`zig build plugin-smoke`——在缓存目录装配六平台插件，校验 ELF/PE/Mach-O 格式、技能逐字节、顶层产物集合、清单版本与 `source: "./"`、启动器在无 Node/Bun 的 PATH 下运行。
- **诚实边界**：macOS arm64 已实测构建、市场安装、技能发现与助手 Bash 命令发现；Windows/Linux 产物已交叉编译并通过格式与装配冒烟，运行行为仍需目标机器实测；Claude Code 尚无本机实测。Linux 产物为静态 musl，glibc 系统预期可直接运行，同样需实测确认。
- **门禁**：`zig build test` + `test-e2e` + `plugin-smoke`；`zig fmt src tools test build.zig` 保持格式。
