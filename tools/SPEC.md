---
id: specrail-tools
type: module-design
status: active
title: tools/ — 构建期工具：技能内嵌与插件装配
parent: specrail
tags: [tools, build]
---

## 责任

构建期工具，两个 host 可执行文件：`embed_skills.zig` 把 `skills/` 校验后逐字内嵌为编译期 Zig 源；
`build_plugin.zig` 把各平台二进制、启动器、技能、清单与许可文件装配成分发用插件树并发布。
唯一调用方是 `build.zig`（`plugin` / `plugin-smoke` 步骤）；不进入任何用户面，也不随产物分发。

## 边界

- **拥有**：内嵌生成物契约、插件树装配与发布语义（暂存 / 替换守卫 / 确定性）、清单重写范围、argv 契约。
- **公开面**：两个 `main(u8)` 的命令行——`embed-skills <skills-dir> <output-file>`；
  `build-plugin --root <dir> --destination <dir> --version <v> --artifact <target> <path>...`
  （`--artifact` 至少一个，root / destination / version / artifacts 缺一即用法错误）。诊断走 stderr
  （前缀 `embed-skills:` / `build-plugin:`），退出 0 / 1。
- **允许依赖**：仅 Zig 标准库 + 共享库面 `src/lib.zig`（import 名 `specrail`），host 目标编译。
  校验复用 `specrail-distribute` 的 `readSkillsFromDir`（与运行时同源）；清单重写复用 `src/json.zig`。
- **禁止**：图 / 查询逻辑；CLI 的参数面与退出码契约（见 `specrail-cli`）；随插件分发的代码。

## 不变量

- **校验同源**：embed 用运行时同一 `readSkillsFromDir` 读取 `skills/`，失败即构建失败——内嵌副本
  与源目录不会漂移。
- **逐字内嵌**：技能字节原样转义进生成源（`"`、`\`、`\n`、`\r`、`\t` 与 C0 / DEL），无改写；
  生成文件自述 do-not-edit，手工改动会在下次构建被覆盖。
- **装配集封闭**：插件顶层恰为 `.claude-plugin` / `.qoder-plugin` / `bin` / `libexec` / `licenses` /
  `skills` / `LICENSE` / `NOTICE` / `README.md` / `runtime.json`——新增顶层条目是契约变更
  （`plugin-smoke` 钉住精确集合与开发期文件的缺席）。
- **只改清单两处**：`plugin.json` 的 `version`（原地替换或末尾追加）；`marketplace.json` 的
  `plugins[].source`（改为 `"./"`，使插件内清单自指）。其余字段与顺序原样保留。
- **暂存后整体发布**：目标已存在且既无 `runtime.json` 又非空 → 拒绝替换（防误删手写目录）；
  合格目标先在同级随机目录 `.specrail-build-<hex>` 完整装配，再删旧目标并 rename 发布（同卷），
  失败清理暂存。
- **确定性**：目录与技能列表一律字节序遍历；同输入装配出同一棵树。
