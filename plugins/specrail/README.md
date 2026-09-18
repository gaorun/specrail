# specrail

跨助手规格 CLI：在仓库中维护类型化规格图，并向编码助手（Qoder / Claude Code / Codex / pi）分发工作流技能与命令。

- 规格图：Markdown + YAML frontmatter，节点以非空 `id` + `type` 入图；
- 工作流：技能与命令由助手执行，specrail 不内置模型与执行引擎；
- 派生说明与许可见 `SPEC.md`、`NOTICE`、`LICENSE`。

## 插件市场安装（Claude Code / Qoder）

插件包含全部 10 个技能和自包含 CLI。用户不需要安装 specrail、Node.js 或 Bun；
运行时版本在构建时固定，不使用 nvm / mise / n 选择的 Node，也不修改用户的 PATH 或版本管理器配置。
插件只在助手的命令执行环境中提供 `specrail`，不会全局安装终端命令。

支持 macOS、Windows、Linux（glibc）的 x64 / arm64；暂不包含 Alpine / musl、32 位平台。

直接使用当前仓库 Git URL 安装，需具备该仓库的 Git/SSH 读取权限。
根市场清单定位仓库内的 `plugins/specrail/`，无需另建分发仓库；维护者须先将该目录连同市场清单提交并推送。

Claude Code 会话内：

```text
/plugin marketplace add git@code.amh-group.com:Y0010495/specrail.git
/plugin install specrail@specrail-marketplace
```

Qoder 终端：

```sh
qoder plugins marketplace add git@code.amh-group.com:Y0010495/specrail.git
qoder plugins install specrail@specrail-marketplace
```

安装后重新加载插件或重启助手会话。技能自动发现，无需再用 `init` 复制一份技能；
助手可直接执行 `specrail list`、`specrail create` 等命令。项目自身的 Node 命令不受影响。

### 构建与本地安装验证（维护者）

使用 `package.json#packageManager` 固定的 Bun 版本：

```sh
bun install --frozen-lockfile
bun run build:plugin             # 六个平台 → plugins/specrail（随 Git 分发）
bun run build:plugin --current   # 仅本机 → dist/plugin-current/specrail（不提交）

qoder plugins validate plugins/specrail
qoder plugins marketplace add "$PWD"
qoder plugins install specrail@specrail-marketplace
```

Claude Code 可用 `/plugin marketplace add <当前仓库的绝对路径>` 验证相同市场入口，
也可用 `claude --plugin-dir <plugins/specrail 的绝对路径>` 临时加载。

- 首次跨平台构建可能下载对应版本的 Bun 运行时；**安装和运行插件时不下载或编译任何依赖**。
- 构建目录包含两端清单、技能、`bin/` 启动器、`libexec/` 原生程序、许可资料和 `runtime.json`。
  启动器按系统和架构选择程序，保留项目工作目录、参数及退出码；不会加载项目 Bun 配置或注入的 Node/Bun 启动选项。
- `plugins/specrail/` 是生成物，但必须整体纳入当前仓库 Git 版本，包括隐藏清单目录和可执行权限。
  修改 CLI、技能、启动器或版本后，重新执行全平台构建，将源码和该目录一起提交；不要手改生成物。
  **不要将 `--current` 产物覆盖到该目录，也不要使用 Git LFS 占位文件代替原生程序**。
  安装缓存只包含这个独立插件目录，不包含源码仓库的 `package.json` / 锁文件，避免触发开发依赖安装。
  构建不会自动提交或推送。
- 全平台产物体积约 435 MiB，用户只运行其中匹配的平台版本。
- 公开分发前须核对固定版本 Bun 的完整第三方许可及 LGPL 对应源码/重链接材料；
  `licenses/bun-<版本>.txt` 是上游许可说明，不是完整合规材料。应用的 Apache-2.0 不替代运行时组件许可。
- 本地已验证 macOS arm64 无 Node 环境、版本管理器 shim 干扰、Qoder 市场安装/技能发现和助手 Bash 命令发现；
  其它平台已交叉编译，尚需目标机器实测；Claude Code 尚未在本机实测。

## CLI 源码开发与本地接入

不使用插件时，仍可通过原来的 Node CLI 分发技能（Node.js ≥ 20.19）：

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
