---
id: specrail-cli
type: submodule-design
status: active
title: cli — 命令层：参数解析、输出、退出码
parent: specrail
tags: [cli, commands]
---

## 责任

命令行入口与命令面：`specrail` 子命令的参数解析（node:util parseArgs）、人读与 `--json` 输出、
退出码契约、错误到 stderr 的映射，以及 init/sync 的编排调用与结果打印。

## 边界

- **拥有**：`src/cli.ts` 入口（含 EPIPE 处理）、dispatch 与 `--help`/`--version`、全局参数
  （`--root`/`--json`/`-h`/`-v`）、每个命令的参数校验、文本渲染（自 ThinkRail tools 逐行移植）、
  退出码映射。
- **公开面**：入口 `src/cli.ts` 经 dispatch 驱动各 `commands/<name>.ts` 导出的
  `run(argv: string[]): Promise<number>`；`args.ts` 的 `UsageError`、`HelpRequested`、
  `VersionRequested`、`parseCommandArgs`、`rootFrom`、`numberFrom`；测试经 `tests/helpers.ts`
  以子进程驱动真实 CLI。
- **允许依赖**：`src/core/`（经其 barrel）、`src/distribute/`、Node 内置模块。命令模块只做
  参数解析、调用与打印。
- **禁止**：任何助手 SDK；不直接读技能源或写助手文件（分发全部经 `src/distribute/`）；退出码
  判断只在 `main` 一处，命令模块只返回值。

## 文件

| 文件 | 职责 |
| --- | --- |
| `src/cli.ts` | shebang 入口：stdout EPIPE 静默退出、`main` 返回值写入 `process.exitCode` |
| `main.ts` | 命令表（单一来源，`--help` 文本由表生成）、dispatch、错误 → 退出码映射 |
| `args.ts` | parseArgs 封装与全局参数；控制信号异常；`rootFrom`/`numberFrom` 取值校验 |
| `out.ts` | `print` / `printJson`——唯一输出口 |
| `version.ts` | 从包内 `package.json` 读版本（源码树与构建产物双路径） |
| `report.ts` | init/sync 结果行（文件数、清理数、规则块） |
| `commands/*.ts` | 10 个命令：解析参数、调用 core/distribute、渲染输出、返回退出码 |

## 不变量

- 退出码契约：`0` 成功（validate 无发现）；`1` 仅 validate 发现问题；`2` 用法与执行错误
  （未知命令或参数、非法取值、id 不存在、路径被拒、IO 失败、无清单的 sync）。
- `--help`/`--version` 在顶层与子命令级都可用且返回 0；`--help` 文本由命令表生成，单一来源。
- `--json` 输出与源 tools 的 details 逐字段一致；文本输出是 tools 文本渲染的移植。
- 错误路径不产生崩溃栈迹：stdout EPIPE 静默退出 0；未识别的内部错误才向上抛。
- 未知参数一律退出 2（parseArgs strict），不静默忽略。
