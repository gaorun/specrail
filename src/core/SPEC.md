---
id: specrail-core
type: submodule-design
status: active
title: core — 规格图模型（pi-free）
parent: specrail
tags: [core, spec-graph]
---

## 责任

pi-free 的规格模型：is-a-spec 规则、frontmatter 解析/序列化与就地编辑（yaml 库；链接与元数据列表
走行内列表）、派生图（parent 树 + depends-on/references/implements DAG + 反向边）、按需内存读索引、
带元数据过滤的内容 grep、有界图切片、结构校验。不 import 任何助手/宿主 SDK，可独立单测
（`core.test.ts`）。

## 边界

- **拥有**：以上全部。文件系统是唯一事实来源；模型是派生的、内存的、只读的。
- **公开面**：`index.ts` barrel；`src/cli/` 只经 barrel 消费，不直接 import 叶子文件。模块自己的
  测试（`core.test.ts`）可直连叶子，以触达刻意不公开的纯函数守卫——`store.ts` 的路径守卫、段解析器
  与 glob 排序比较器。
- **允许依赖**：`yaml`；Node 内置模块。
- **禁止**：任何助手/宿主 SDK（pi、typebox 等）与任何 ThinkRail 包——这是 core 可独立单测的保证。

## 派生声明

本目录复制自 ThinkRail `packages/spec-graph/core/`（Copyright 2026 JetBrains s.r.o.，Apache-2.0），
已修改：去除宿主指向与品牌引用，改写模块描述以适配 specrail 边界。行为不变量与实现自源原样保留
（见下）；范围变化需同步 `NOTICE`。

## 叶子与依赖图

无环单向：`parse` 为根，`graph` 依赖它，`query`/`validate`/`store` 依赖 `graph`。barrel 只做再导出，
不加逻辑。

| 叶子 | 职责 | 依赖 |
| --- | --- | --- |
| `parse.ts` | 文件 → `{ frontmatter, body }`；is-a-spec 规则；frontmatter 解析（有损读方言）+ 序列化；`updateFrontmatterText` 无损就地编辑；`FIELDS` 注册表与有限词汇元组 | — |
| `graph.ts` | 文件 → 节点 + 边（parent 树、DAG + 反向）；重复 id 记录 | `parse` |
| `query.ts` | 带元数据过滤的内容 grep；有界图切片 | `parse`, `graph` |
| `validate.ts` | 悬空链接、重复 id、parent 环 | `parse`, `graph` |
| `store.ts` | `SpecIndex`：按需 fs glob + 每文件解析缓存 + 记忆化图；可索引路径规则（`resolveSpecPath`） | `parse`, `graph`, `query` |

## 不变量（自源保留）

- `core/` 下任何位置不得 import 任何助手/宿主 SDK（pi、typebox 等）。
- `buildGraph` 是纯函数（同输入 → 同输出）；索引按 `(mtimeMs, size)` 重新校验每个文件、记忆化图，
  绝不提供过期图。
- glob 先把每个目录的条目过滤成遍历候选（未忽略目录 + `.md` 文件），**然后**才做归一化与排序：
  满是无关条目的目录只付出一次被丢弃的扫描。
- 该顺序是**全序**：候选按 **NFC 归一化**名比较，同键再按原始名的码元打破平局。因此规格顺序——
  以及重复 `id` 的胜出文件——在每个文件系统上都一致：不是 `readdir` 的偶然顺序，不因分解（NFD）名
  而不同，也不因两个规范等价拼写（预组合 `é` vs `e\u0301`）共享同一个 NFC 键而被稳定排序留在原处。
  目录与 `.md` 文件保持**同一个**候选列表，子目录落位于其兄弟文件之间而非全体之前或之后，
  规格序列端到端按名排序。过滤-再排序的改写**保持**了这一性质而非引入它；测试存在，是因为
  “两个列表”是显而易见的写法，且会悄悄挪动重复 `id` 的胜者。
- 重复 `id` 时，该顺序中的第一个文件赢得节点槽位；重复集合被记录供 `validate` 报告。
- `resolveSpecPath` 是“索引是否可能看到此路径”的唯一答案，并回答**规范化相对路径**，使调用方
  永远无法报告一个索引不会产生的身份。要求：根内相对、位于根内、`.md`、位于忽略目录之外、根存在、
  根下任何组件都不是符号链接——逐组件用 `lstat` 检查（含悬空链接），因为 glob 从不下降符号链接。
  在 Windows 上，含冒号的路径在归一化之前即被拒绝：同时封死驱动器相对路径（`C:..\outside.md`，
  `isAbsolute` 不识别）与 NTFS 备用数据流（`file:SPEC.md`，`readdir` 不可见）。归一化后残留的每个
  `..` 段同样被拒；规范化绝对结果还必须通过最终的 `relative(root, target)` 包含检查。这些重叠的
  门禁是刻意的：路径语法、归一化与逐组件规范化不得互相拆台。可移植的 `win32` 算术测试在每个宿主上
  钉住逃逸；符号链接规则是字符串检查与 `realpath` 比较都会漏掉的一环：链接无论离开项目、落进忽略
  目录、还是指回已索引目录都被拒绝——每种情况下它创建的文件对其余规格工具都不可见。
- `resolveSpecPath` 在判定或报告前把每个组件规范化为其**磁盘拼写**。字节已与其父目录某条目一致的
  组件按原样采用；在该文件系统上可解析但字节不完全匹配任何条目（大小写不敏感或 Unicode 折叠的
  文件系统）的组件，变成父目录中唯一按 `normalize("NFC").toLowerCase()` 相等的条目。零个或两个
  这样的条目是**错误**：宁失败也不猜身份。规范化在第一个不可解析组件处停止，其余保留调用方拼写，
  因为在大小写敏感文件系统上，新建 `Docs/` 与既有 `docs/` 并排确实是 glob 会看到的新目录。
  `rel` 与 `abs` 由这些规范段组装，绝不来自词法拼写。词法 `rel` 正是让 `NODE_MODULES/SPEC.md`
  在大小写不敏感文件系统上报告一个 glob 永不产生的身份（写入实际落进 `node_modules/`）的原因。
  `.md` 规则判定两次：调用方字符串一次、规范 `rel` 再一次——因为规范化为 `SPEC.MD` 的叶子是
  逐字节 glob 永不索引的文件。存在性用 `lstat` 探测，悬空符号链接也算可解析并仍进入上文的
  符号链接拒绝。
  规范化读取**父目录**的列表，所以每个存在的父目录都被列出——不只是组件存在的那些——存在但无法
  列出的父目录是**错误**，绝不是空列表。那次 `readdir` 正是 glob 在该处的调用：解析器无法列出的
  目录，也是 glob 放弃的目录；写在其下的规格会像 `node_modules` 里的一样不可见。
- **写路径宁可多拒；读路径保持精确。** `resolveSpecPath` 用每组件 `normalize("NFC").toLowerCase()`
  折叠匹配 `IGNORED_DIRS`，因此拒绝任何拼写的 `NODE_MODULES/SPEC.md`；glob 只匹配逐字节的
  `readdir` 名。两种错误不对称：解析器多拒给调用方可行动的理由；glob 多跳会把人真的命名为
  `Build/` 的目录静默排除出索引。仅凭规范化触达不到写路径，因为它只对已存在的组件发言：在尚未
  安装 `node_modules` 的项目上，`NODE_MODULES/SPEC.md` 能解析、在大小写不敏感文件系统上创建真实
  `node_modules`、并把其下每个依赖交给 glob 索引。把 glob 也折叠毫无收益——已安装的 `node_modules`
  磁盘上就是小写，逐字节检查已跳过——却要付出 `Build/` 的代价，因此 glob 保持逐字节。折叠完全够
  不到的情形：由助手自身的 write 工具写进 `NODE_MODULES/` 的规格不经过 `resolveSpecPath`。
- `SpecNode.type` 保持 `string`：读模型索引磁盘上的任何内容，故容忍任意 `type`；`SPEC_TYPES` 词汇
  只约束 `specrail create` 的创作面，绝不约束图。
- 有限词汇（`SPEC_TYPES`、`SPEC_STATUSES`、`SLICE_DIRECTIONS`、`LINK_KINDS`、`IDENTITY_FIELDS`）
  与 frontmatter 字段名（`FIELDS` 注册表）单一来源 `as const`——无重复字面量列表，改名是一行改动。
  `core/` 不依赖 typebox。
- 读路径把 frontmatter 强制为标量/字符串数组方言（有损——嵌套映射与注释被丢弃），对派生模型足够。
  写路径（`updateFrontmatterText`）是**无损**的：就地变更活的 `yaml` Document，未触碰字段保持顺序，
  注释/嵌套值存活。字段顺序**保持，绝不重排**——`FIELD_ORDER` 只是 `specrail create` 构建**新**
  frontmatter 的顺序。围栏内行去掉 `\r` 是 CRLF 文件能解析的原因。
- 写路径**只重写 frontmatter 块**：正文逐字节拼回，前导 BOM 复位，重写块使用的行尾取自 frontmatter
  自身的首换行（LF 或 CRLF）。不从正文推断任何东西——正文恰好混用行尾的文件保留它的每个正文字节，
  这使“`specrail update` 永不编辑正文”对字节成立，而不只对字段成立。
- 读路径承担对偶义务：`grepSpecs` 按 `\n` 切分，匹配前丢弃尾随 `\r` 与前导 BOM，使锚定模式在 LF、
  CRLF、BOM 前缀的规格上行为一致——否则 BOM 会把第 1 行从每个 `^` 模式面前藏起来。
