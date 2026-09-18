---
id: specrail-distribute
type: submodule-design
status: active
title: distribute — 助手适配器、生成物与清单治理
parent: specrail
tags: [distribute, adapters, init, sync]
---

## 责任

把 `skills/` 技能源渲染为各助手目录下的技能与命令文件，写入 `AGENTS.md` 托管规则块，并以
`.specrail/config.json` 清单治理生成物：`init` 选定助手并首次分发，`sync` 按清单刷新与清理。

## 边界

- **拥有**：助手面表（工具 → 技能根 / 命令面 / frontmatter / 参数注入）、技能源读取（frontmatter 解析）、
  期望文件集、写盘与清单内删除、AGENTS.md 规则块。
- **公开面**：`adapters.ts` 的 `GeneratedFile`、`SkillFile`、`SkillMeta`、`SkillSource`、`SKILL_PREFIX`、
  `TOOLS`、`Tool`、`renderSkillFiles`、`renderCommandFiles`；`config.ts` 的 `DistributeError`、`errorDetail`、
  `CONFIG_DIR`、`CONFIG_PATH`、`DistributeConfig`、`readConfig`、`writeConfig`；`rule.ts` 的 `RULE_BEGIN`、
  `RULE_END`、`RULE_TEXT`、`hasRuleBlock`、`upsertRuleBlock`；`generate.ts` 的 `InitOptions`、`SyncOptions`、
  `ApplyReport`、`packagedSkillsDir`、`readSkills`、`expectedFiles`、`initProject`、`syncProject`。
- **允许依赖**：`yaml`、Node 内置模块。`src/cli/` 只经上述叶子消费（`commands/{init,sync}.ts` 做参数解析
  与打印，编排全部在 `generate.ts`，测试直接驱动编排）。
- **禁止**：`src/core/`（distribute 不解析规格图）；任何助手 SDK；不写 stdout、不改退出码——错误以
  `DistributeError` 抛出，由 `src/cli/main.ts` 映射为退出码 2。

## 叶子与依赖图

单向无环：`config` → `adapters`（取工具表），`rule` → `config`（错误类型），`generate` → `adapters`/`config`/`rule`。

| 叶子 | 职责 | 依赖 |
| --- | --- | --- |
| `adapters.ts` | 助手面表与纯渲染：技能文件按工具根落位、命令文件按工具 frontmatter 生成 | — |
| `config.ts` | `.specrail/config.json` 读写与形状/路径校验；`DistributeError` 与错误消息工具 | `adapters` |
| `rule.ts` | AGENTS.md 托管块：标记常量、逐字规则文本、就地 upsert、块存在性判断 | `config` |
| `generate.ts` | 技能源读取与校验、期望文件集、写盘与清单内删除、init/sync 编排、打包内技能源定位 | `adapters`, `config`, `rule` |

## 适配器核实结论

依据（逐文件读取，只读）：OpenSpec 1.12.0 的
`.../@fission-ai/openspec/dist/core/command-generation/adapters/`（30 个适配器）及其
`command-generation/{registry,invocation,generator}.js`、`config.js`、`command-surface.js`、
`shared/skill-paths.js`、`legacy-cleanup.js`、`shared/allowed-tools.js`；本机既有布局 `~/.qoder`、`~/.claude`、
`~/.codex`、`~/.agents`、`my-repos/thinkrail/.pi/prompts`；pi 官方文档（`@earendil-works/pi-coding-agent`
的 `docs/prompt-templates.md`、`docs/skills.md`）。

| 助手 | 技能根 | 命令面 | frontmatter | 参数注入 |
| --- | --- | --- | --- | --- |
| pi | `.pi/skills/<name>/SKILL.md` | `.pi/prompts/<name>.md` | 仅 `description` | `$@`（命令体带 `**Input**: $@`） |
| qoder | `.qoder/skills/<name>/SKILL.md` | `.qoder/commands/specrail/<id>.md` | `name` / `description` / `category` / `tags` | 无占位符（样本不使用，参数由助手追加） |
| claude | `.claude/skills/<name>/SKILL.md` | `.claude/commands/specrail/<id>.md` | `name` / `description` / `allowed-tools` / `category` / `tags` | `$ARGUMENTS` |
| codex | `.agents/skills/<name>/SKILL.md` | 无（技能即入口） | — | 技能名调用 |

- **codex 无命令面是核实结论，不是遗漏**：`command-generation/registry.js` 注册的表里没有 codex；
  `command-surface.js` 把 codex 判为 `skills-invocable`，并只在 `adapter-backed` 时生成命令文件。codex 的
  技能根取自 `config.js`：`{ value: 'codex', skillsDir: '.agents', legacySkillsDirs: ['.codex'],
  detectionPaths: ['.agents/skills', '.codex/skills'] }`，`shared/skill-paths.js` 把它解析为
  `<root>/.agents/skills/<name>/SKILL.md`。`legacy-cleanup.js` 把 `.codex/prompts/openspec-*.md`（项目级）与
  `<CODEX_HOME>/prompts`（全局）登记为**已弃用**命令面，其注释写明 Codex 已转为 “skills-only delivery”。
  本机 `~/.agents/skills/` 是活跃的共享技能根，`~/.codex/` 下没有 prompts/commands/skills。
- **qoder**（已核实，保持）：`adapters/qoder.js` → `.qoder/commands/opsx/<id>.md` + `name/description/category/
  tags`；本机 `~/.qoder/commands/*.md` 是扁平全局命令，项目级按命名空间目录组织，与适配器一致；
  `~/.qoder/skills/<name>/SKILL.md` 佐证技能形态，技能根来自 `config.js` 的 `skillsDir: '.qoder'`。
- **claude**：`adapters/claude.js` → `.claude/commands/opsx/<id>.md` + `name/description/allowed-tools/category/
  tags`；`allowed-tools` 的语义见 `shared/allowed-tools.js`（只预授权、不限制其他工具），本实现填
  `Bash(specrail:*)`。技能根 `.claude/skills` 来自 `config.js`。`$ARGUMENTS` 是 Claude Code 文档约定；本机未
  安装 Claude Code，这一项无本机佐证。
- **pi**（已核实，保持）：`adapters/pi.js` → `.pi/prompts/opsx-<id>.md`，frontmatter 仅 `description`，
  `injectPiArgs` 在正文不含 `$@`/`$ARGUMENTS` 时补 `**Provided arguments**: $@`。pi 文档确认项目级模板为
  `.pi/prompts/*.md`（非递归、按文件名注册命令）、项目级技能为 `.pi/skills/`（目录含 `SKILL.md`），模板参数
  支持 `$1`/`$@`/`${1:-默认}`；`thinkrail/.pi/prompts/*.md` 是同一形态的实例。
- 命令体统一为“读取并执行该工具下的技能路径”，按各工具占位符追加 `**Input**: …`；frontmatter 标量一律用
  `JSON.stringify` 输出（双引号 + 转义），值中的引号、冒号、控制字符都不会破坏 YAML。

## 生成物与清单治理

- **期望文件集** = f(技能源目录, 所选工具)：按字节序读取技能源（目录名须等于 frontmatter `name`、以
  `specrail-` 开头、`description` 非空；`SKILL.md` 与兄弟文档整体逐字节复制），再按工具渲染技能与命令文件，
  最后按路径字节序合并。技能源目录是**参数**：CLI 指向打包内的 `skills/`（相对 `import.meta.url` 取
  `../skills/`、`../../skills/` 先存在者），测试指向临时 fixture。
- `.specrail/config.json` = `{ version, tools, files }`：`version` 为当前 specrail 版本；`tools` 保序去重；
  `files` 为期望文件集的相对路径。读取时校验形状与路径安全（根内相对、拒绝绝对路径/`..`/反斜杠），
  损坏或不合法清单以 `DistributeError` 报出可执行的理由，绝不静默降级。
- **清单治理只删自己记录过的**：init 与 sync 都只删除“上次 `files` 记录、本次不再期望”的路径；未记录文件
  （用户自建命令、AGENTS.md 等）永不触碰。记录过但已在磁盘上缺失的文件会被重新生成；不再期望的空目录不清理。
- init 与 sync 共用同一套对账（算期望集 → 写盘 → 清单内删除 → 规则块 → 写清单），差异只在工具来源：
  init 取 `--tools`（必填、逗号分隔、去重保序，非法即退出码 2），sync 取清单 `tools`（无清单即退出码 2 并提示
  先 `specrail init`）。因此换成更少工具重跑 init 也会清理旧产物——否则它们会永远失去记录。
- **AGENTS.md 托管块**：`<!-- specrail:rule:begin -->` … `<!-- specrail:rule:end -->`。`init --rule` 创建或更新；
  块已存在时 sync（无论是否带 `--rule`）刷新块内文本，块外字节不动——标记本身就是“已选择托管”的记录，
  故 `config.json` 不再另存 rule 开关。新块追加在文件末尾，原有内容逐字节保留。

## 不变量

- 适配器是纯渲染（无 fs）；fs 只出现在 `config`/`rule`/`generate` 三个叶子。
- 排序一律按字节（`compareText`），不依赖 locale，生成物与清单顺序跨机器一致。
- 目录名 = frontmatter `name` = `specrail-<id>`；命令名 `id` 只由 `name` 前缀派生，不另设来源。
- 技能内容不重写：只有命令文件与清单是生成的，技能文件逐字节复制。
- 校验先于写盘：技能源与清单在写任何文件前完成校验（init 在技能源缺失时不留下清单）。
