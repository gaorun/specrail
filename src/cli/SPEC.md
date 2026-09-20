---
id: specrail-cli
type: submodule-design
status: active
title: cli — 命令层：参数解析、输出、退出码
parent: specrail
tags: [cli, commands]
---

## 责任

命令行入口与命令面：`specrail` 子命令的参数解析（内置的 node:util parseArgs 兼容层，错误消息逐字
对齐）、人读与 `--json` 输出（`JSON.stringify(v,null,2)` 的精确复刻）、退出码契约、错误到 stderr 的
映射，以及 init/sync 的编排调用与结果打印。

## 边界

- **拥有**：`src/main.zig` 入口（EPIPE 静默退出）、dispatch 与 `--help`/`--version`、全局参数
  （`--root`/`--json`/`-h`/`-v`）、每个命令的参数校验、文本渲染、退出码映射。
- **公开面**：`cli/main.zig` 的 dispatch 驱动各 `commands/<name>.zig` 导出的
  `run(ctx) !u8`；`args.zig` 的 `parse`（Help/Version/Usage 信号）、`usageError`、`rootFrom`、
  `numberFrom`；`json.zig`（`src/json.zig`，与 distribute 共享的精确 JSON 输出器）；
  测试经 `test/e2e_*.zig` 以子进程驱动真实 CLI（golden 语料回放）。
- **允许依赖**：仅 Zig 标准库；`src/core/` 与 `src/distribute/` 经叶子文件相对 import；`src/json.zig` /
  `src/errors.zig`；构建期注入的 `build_options` 与匿名 `embedded_skills`（由 `tools/` 生成）。命令模块
  只做参数解析、调用与打印。
- **禁止**：任何助手 SDK；不直接读技能源或写助手文件（分发全部经 `src/distribute/`）；退出码
  判断只在 `main` 一处，命令模块只返回值。

## 文件

| 文件 | 职责 |
| --- | --- |
| `src/main.zig` | 进程入口：`Init` 参数、stdout EPIPE 静默退出、退出码 |
| `cli/main.zig` | 命令表（单一来源，`--help` 文本由表生成）、dispatch、错误 → 退出码映射 |
| `cli/args.zig` | parseArgs 兼容解析与全局参数；Help/Version/Usage 信号；`rootFrom`/`numberFrom` 取值校验 |
| `cli/out.zig` | `print` / `printRaw` / `err`——唯一输出口（缓冲写，退出前冲刷） |
| `cli/version.zig` | 版本常量（构建期读 `VERSION` 注入 `build_options`） |
| `cli/report.zig` | init/sync 结果行（文件数、清理数、规则块）与 `--json` 报告 |
| `cli/context.zig` | 命令上下文（io/arena/输出/argv） |
| `commands/*.zig` | 10 个命令：解析参数、调用 core/distribute、渲染输出、返回退出码 |

## 不变量

- 退出码契约：`0` 成功（validate 无发现）；`1` 仅 validate 发现问题；`2` 用法与执行错误
  （未知命令或参数、非法取值、id 不存在、路径被拒、IO 失败、无清单的 sync）。
- `--help`/`--version` 在顶层与子命令级都可用且返回 0；`--help` 文本由命令表生成，单一来源。
- `--json` 输出是 `JSON.stringify(v, null, 2)` 的精确复刻：两空格缩进、`": "` 分隔、键按调用序、
  空容器 `{}`/`[]`、C0 控制字符 `\u00XX`、缺省键按 undefined 省略。
- parseArgs 兼容层错误消息逐字对齐（含 `Unknown option '--x'. …` 结尾的不对称引号与
  `argument is ambiguous` 三行消息）。
- 错误路径不产生崩溃栈迹：stdout EPIPE 静默退出 0；未识别的内部错误才向上抛。
- 未知参数一律退出 2（strict 解析），不静默忽略；`--` 之后的 token 一律按位置参数处理。
