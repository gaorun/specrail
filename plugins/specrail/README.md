# specrail

跨助手规格 CLI：在仓库中维护类型化规格图，并向编码助手（Qoder / Claude Code / Codex / pi）分发工作流技能与命令。

- 规格图：Markdown + YAML frontmatter，节点以非空 `id` + `type` 入图；
- 工作流：技能与命令由助手执行，specrail 不内置模型与执行引擎；
- 实现：纯 Zig（无运行时依赖），交叉编译为六个平台的静态可执行文件；
- 派生说明与许可见 `SPEC.md`、`NOTICE`、`LICENSE`。

## 插件市场安装（Claude Code / Qoder）

插件包含全部 10 个技能和自包含 CLI（约 3.2 MiB，六个平台合计；单个平台 0.4–0.75 MiB）。
用户不需要安装 specrail、Node.js、Bun 或 Zig；运行时二进制静态链接，不读取系统版本管理器配置，
也不修改用户的 PATH。

支持 macOS、Windows、Linux 的 x64 / arm64；Linux 产物为静态 musl 构建，glibc 与 musl（Alpine）系统均可直接运行。

直接使用当前仓库 Git URL 安装，需具备该仓库的 Git/SSH 读取权限。
根市场清单定位仓库内的 `plugins/specrail/`，无需另建分发仓库；维护者须先将该目录连同市场清单提交并推送。

Claude Code 会话内：

```text
/plugin marketplace add git@github.com:gaorun/specrail.git
/plugin install specrail@specrail-marketplace
```

Qoder 终端：

```sh
qoder plugins marketplace add git@github.com:gaorun/specrail.git
qoder plugins install specrail@specrail-marketplace
```

安装后重新加载插件或重启助手会话。技能自动发现，无需再用 `init` 复制一份技能；
助手可直接执行 `specrail list`、`specrail create` 等命令。项目自身的工具链不受影响。

## pi 包安装

pi 用包安装（`pi install`）获得同样的 10 个技能与自包含 CLI。pi 的 git 源只支持整仓库克隆
（无子目录包），因此包根就是本仓库：

```sh
pi install git:git@github.com:gaorun/specrail      # 全局安装（SSH）
pi install -l git:git@github.com:gaorun/specrail   # 项目级：写入 .pi/settings.json，随仓库共享
pi update --extensions                             # 更新已装包
pi remove git:git@github.com:gaorun/specrail       # 卸载
```

- 技能来自 `skills/`（pi 的约定目录，`SPEC.md` 按非技能忽略）；CLI 由根扩展 `extensions/specrail.js`
  把 `plugins/specrail/bin` 前置进会话 PATH——不写用户 shell 配置、不改 pi 设置，卸载即失效。
- 整仓库克隆意味着安装内容包含源码树与六个平台产物；克隆后不执行任何安装脚本（无根 `package.json`
  ——有清单会触发 `npm install`，与「不依赖 Node / npm」相悖）。
- 源必须带 pi 的 `git:` 前缀：`git:git@github.com:gaorun/specrail`（SSH；HTTPS 为
  `git:github.com/gaorun/specrail`，注意是斜杠）；省略前缀会被当成本地路径。
- `@<ref>` 可锁定版本（需先打 tag）：`pi install git:git@github.com:gaorun/specrail@v0.1.0`。
- 与 `specrail init --tools pi` 二选一：两条路都给同名技能，重复会发现重名告警（保留先发现者）。

### 构建与本地安装验证（维护者）

需要 Zig 0.16.0（唯一构建依赖）：

```sh
zig build                  # 本机开发二进制 → zig-out/bin/specrail
zig build plugin           # 六个平台全部交叉编译并装配 → plugins/specrail（随 Git 分发）
zig build plugin -Dcurrent # 仅本机平台，输出至 plugins/specrail（也可 -Doutdir=<dir> 覆盖）
zig build test             # 单元测试（core / cli / distribute）
zig build test-e2e         # 端到端：golden 语料回放（CLI 行为契约）
zig build plugin-smoke     # 在缓存目录装配插件并做冒烟检查

qoder plugins validate plugins/specrail
qoder plugins marketplace add "$PWD"
qoder plugins install specrail@specrail-marketplace

cd /tmp/pi-probe             # pi 包：不能在仓库根执行，-l 会写当前目录的 .pi/settings.json
pi install -l -a /path/to/specrail   # 验证技能发现与 specrail 命令
pi remove -l -a /path/to/specrail    # 清理
```

- 一台机器、一条命令即可产出全部六个平台产物；不下载其它工具链，不依赖各平台机器。
- 构建目录包含两端清单、技能、`bin/` 启动器、`libexec/` 原生程序、许可资料和 `runtime.json`。
  启动器按系统和架构选择程序，保留项目工作目录、参数及退出码。
- `plugins/specrail/` 是生成物，但必须整体纳入当前仓库 Git 版本，包括隐藏清单目录和可执行权限。
  修改 CLI、技能或版本后，重新执行 `zig build plugin`，将源码和该目录一起提交；不要手改生成物。
  应用版本改 `VERSION`（同时用于插件清单与 `runtime.json`）；Zig 工具链版本随构建环境固定为 0.16.0。
- 技能文本在构建期由 `tools/embed_skills.zig` 校验（目录名 = frontmatter `name`、`specrail-` 前缀、
  description 非空）并嵌入二进制；构建失败即校验失败。
- 全平台产物体积约 3.2 MiB，用户只运行其中匹配的平台版本。
- 公开分发前请核对 `NOTICE` 与 `licenses/` 中的运行时时组件许可（Zig 标准库 / compiler-rt，MIT）。
- 本地已验证 macOS arm64 的构建、插件市场安装、技能发现与助手 Bash 命令发现；pi 0.85.1 的包安装
  （技能发现 + 会话内 `specrail` 命令）同样已实测；其它平台已交叉编译并通过格式冒烟，尚需目标机器实测；
  Claude Code 与非 macOS 平台的 pi 尚未在本机实测。

## init / sync 生成什么

- `skills/` 下的技能按助手落位（如 `.qoder/skills/specrail-<name>/SKILL.md`、`.pi/prompts/specrail-<name>.md`），
  逐字节复制，不做内容改写；技能内容编译期内嵌于 CLI，作为分发的源真相；
- `.specrail/config.json` 记录所选助手与生成文件清单；`specrail sync` 按清单刷新内容，并清理不再选择的助手产物——
  只动清单记录过的文件，用户自建文件永不触碰；
- `.specrail/.gitignore`（`context/`）保证技能工作流使用的临时文档不进入 git；
- `--rule`（或此后任意一次 `sync`）维护 AGENTS.md 中的 `specrail:rule` 托管块，块外内容不动。

## 命令面

`init` `sync` `list` `show` `grep` `graph` `create` `update` `delete` `validate`
（`--help` 查看参数；退出码：0 成功、1 validate 发现问题、2 用法/执行错误。）
`grep --regex` 使用内置子集正则引擎（支持常用语法；不支持 lookaround、反向引用与 `\b`）。

## 开发

源码结构：`src/core/`（规格图核心与子集正则）、`src/cli/`（命令层）、`src/distribute/`（助手适配器与
init/sync 编排）、`tools/`（构建期工具）。测试：`zig build test`（单元）、`test-e2e`（golden 回放）、
`plugin-smoke`（装配产物冒烟）。`zig fmt src tools test build.zig` 统一格式。
