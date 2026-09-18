import { describe, expect, test } from "bun:test";
import { makeFixtureRepo, runCli, writeFixtureFile } from "./helpers.ts";

describe("list", () => {
	test("列出全部节点并按路径排序", () => {
		const root = makeFixtureRepo();
		const result = runCli(["list", "--root", root]);
		expect(result.status).toBe(0);
		expect(result.stdout).toBe(
			[
				"goal [goal-and-requirements] — 目标 (goal.md)",
				"mod-a [module-design] — A 模块 (mods/a/SPEC.md)",
				"mod-b [module-design] (mods/b/SPEC.md)",
				"",
			].join("\n"),
		);
	});

	test("--type 只列出该类型的节点", () => {
		const root = makeFixtureRepo();
		const result = runCli(["list", "--type", "module-design", "--root", root]);
		expect(result.status).toBe(0);
		expect(result.stdout.trimEnd().split("\n")).toHaveLength(2);
		expect(result.stdout).not.toContain("goal");
		expect(result.stdout).toContain("mod-a");
		expect(result.stdout).toContain("mod-b");
	});

	test("--tag 只列出携带该标签的节点", () => {
		const root = makeFixtureRepo();
		const result = runCli(["list", "--tag", "core", "--root", root]);
		expect(result.status).toBe(0);
		expect(result.stdout).toBe("mod-a [module-design] — A 模块 (mods/a/SPEC.md)\n");
	});

	test("--json 输出 {id,type,title,path} 数组", () => {
		const root = makeFixtureRepo();
		const result = runCli(["list", "--json", "--root", root]);
		expect(result.status).toBe(0);
		expect(JSON.parse(result.stdout)).toEqual([
			{ id: "goal", type: "goal-and-requirements", title: "目标", path: "goal.md" },
			{ id: "mod-a", type: "module-design", title: "A 模块", path: "mods/a/SPEC.md" },
			{ id: "mod-b", type: "module-design", path: "mods/b/SPEC.md" },
		]);
	});
});

describe("show", () => {
	test("输出节点、路径、正向链接与反向链接", () => {
		const root = makeFixtureRepo();
		const result = runCli(["show", "mod-a", "--root", root]);
		expect(result.status).toBe(0);
		const lines = result.stdout.trimEnd().split("\n");
		expect(lines[0]).toBe("mod-a [module-design] — A 模块");
		expect(lines[1]).toBe("path: mods/a/SPEC.md");
		expect(result.stdout).toContain("links:");
		expect(result.stdout).toContain("parent -> goal (goal.md)");
		expect(result.stdout).toContain("depends-on -> mod-b (mods/b/SPEC.md)");
		expect(result.stdout).toContain("referenced by");
	});

	test("反向链接列出引用该节点的源", () => {
		const root = makeFixtureRepo();
		const result = runCli(["show", "goal", "--root", root]);
		expect(result.status).toBe(0);
		expect(result.stdout).toContain("referenced by:");
		expect(result.stdout).toContain("parent -> mod-a (mods/a/SPEC.md)");
		expect(result.stdout).toContain("parent -> mod-b (mods/b/SPEC.md)");
	});

	test("缺失的链接目标标记为 missing", () => {
		const root = makeFixtureRepo();
		writeFixtureFile(
			root,
			"mods/d/SPEC.md",
			"---\nid: mod-d\ntype: module-design\nparent: goal\ndepends-on:\n  - phantom\n---\n\n## Responsibility\ndangling target\n",
		);
		const shown = runCli(["show", "mod-d", "--root", root]);
		expect(shown.status).toBe(0);
		expect(shown.stdout).toContain("depends-on -> phantom (missing)");
		const graphed = runCli(["graph", "mod-d", "--direction", "neighbors", "--root", root]);
		expect(graphed.status).toBe(0);
		expect(graphed.stdout).toContain("missing targets: phantom");
	});

	test("--json 与源 details 逐字段一致", () => {
		const root = makeFixtureRepo();
		const result = runCli(["show", "mod-a", "--json", "--root", root]);
		expect(result.status).toBe(0);
		expect(JSON.parse(result.stdout)).toEqual({
			id: "mod-a",
			type: "module-design",
			title: "A 模块",
			path: "mods/a/SPEC.md",
			frontmatter: {
				id: "mod-a",
				type: "module-design",
				title: "A 模块",
				parent: "goal",
				"depends-on": ["mod-b"],
				tags: ["core"],
			},
			links: [
				{ kind: "parent", target: "goal", path: "goal.md" },
				{ kind: "depends-on", target: "mod-b", path: "mods/b/SPEC.md" },
			],
			reverseLinks: [],
		});
	});

	test("未知 id 返回 2 且 stderr 报错", () => {
		const root = makeFixtureRepo();
		const result = runCli(["show", "missing", "--root", root]);
		expect(result.status).toBe(2);
		expect(result.stderr).toContain('No spec with id "missing".');
	});

	test("缺少 id 参数返回 2", () => {
		const root = makeFixtureRepo();
		expect(runCli(["show", "--root", root]).status).toBe(2);
	});
});

describe("grep", () => {
	test("按内容匹配并输出 path:line", () => {
		const root = makeFixtureRepo();
		const result = runCli(["grep", "widget", "--ignore-case", "--root", root]);
		expect(result.status).toBe(0);
		expect(result.stdout).toContain("1 match(es):");
		expect(result.stdout).toContain("mods/a/SPEC.md:13: widget rendering");
	});

	test("只匹配 spec 文件", () => {
		const root = makeFixtureRepo();
		const result = runCli(["grep", "not a spec", "--root", root]);
		expect(result.status).toBe(0);
		expect(result.stdout).toContain("No matches.");
	});

	test("默认忽略大小写", () => {
		const root = makeFixtureRepo();
		const result = runCli(["grep", "WIDGET", "--root", root]);
		expect(result.status).toBe(0);
		expect(result.stdout).toContain("mods/a/SPEC.md:13: widget rendering");
	});

	test("无匹配输出 No matches. 且返回 0", () => {
		const root = makeFixtureRepo();
		const result = runCli(["grep", "zzz-nothing", "--root", root]);
		expect(result.status).toBe(0);
		expect(result.stdout.trimEnd()).toBe("No matches.");
	});

	test("--regex 按正则匹配", () => {
		const root = makeFixtureRepo();
		const result = runCli(["grep", "w.dget", "--regex", "--root", root]);
		expect(result.status).toBe(0);
		expect(result.stdout).toContain("mods/a/SPEC.md:13: widget rendering");
	});

	test("--regex 非法正则返回 2", () => {
		const root = makeFixtureRepo();
		const result = runCli(["grep", "(", "--regex", "--root", root]);
		expect(result.status).toBe(2);
		expect(result.stderr).toContain("Invalid search pattern");
	});

	test("--type / --parent / --depends-on 收窄范围", () => {
		const root = makeFixtureRepo();
		expect(runCli(["grep", "storage", "--type", "module-design", "--root", root]).stdout).toContain(
			"mods/b/SPEC.md:8: storage",
		);
		const byParent = runCli(["grep", "Responsibility", "--parent", "goal", "--root", root]);
		expect(byParent.stdout).toContain("2 match(es):");
		expect(byParent.stdout).toContain("mods/a/SPEC.md:12: ## Responsibility");
		expect(byParent.stdout).toContain("mods/b/SPEC.md:7: ## Responsibility");
		const byDependsOn = runCli(["grep", "rendering", "--depends-on", "mod-b", "--root", root]);
		expect(byDependsOn.stdout).toContain("mods/a/SPEC.md:13: widget rendering");
	});

	test("--limit 截断并标记 truncated", () => {
		const root = makeFixtureRepo();
		const result = runCli(["grep", "Responsibility", "--limit", "1", "--root", root]);
		expect(result.status).toBe(0);
		expect(result.stdout).toContain("1 match(es) (truncated):");
	});

	test("--json 输出 matches 与 truncated", () => {
		const root = makeFixtureRepo();
		const result = runCli(["grep", "widget", "--json", "--root", root]);
		expect(result.status).toBe(0);
		expect(JSON.parse(result.stdout)).toEqual({
			matches: [{ path: "mods/a/SPEC.md", line: 13, snippet: "widget rendering" }],
			truncated: false,
		});
	});

	test("缺少 pattern 参数返回 2", () => {
		const root = makeFixtureRepo();
		expect(runCli(["grep", "--root", root]).status).toBe(2);
	});
});

describe("graph", () => {
	test("subtree 沿 parent 树向下展开", () => {
		const root = makeFixtureRepo();
		const result = runCli([
			"graph",
			"goal",
			"--direction",
			"subtree",
			"--depth",
			"2",
			"--root",
			root,
		]);
		expect(result.status).toBe(0);
		expect(result.stdout).toContain('Slice of "goal" (subtree, depth 2):');
		expect(result.stdout).toContain("nodes (3):");
		expect(result.stdout).toContain("mod-a [module-design] — A 模块 (mods/a/SPEC.md)");
		expect(result.stdout).toContain("mod-b [module-design] (mods/b/SPEC.md)");
		expect(result.stdout).toContain("edges (2):");
		expect(result.stdout).toContain("mod-a --parent--> goal");
		expect(result.stdout).toContain("mod-b --parent--> goal");
	});

	test("ancestors 沿 parent 链向上展开", () => {
		const root = makeFixtureRepo();
		const result = runCli(["graph", "mod-a", "--direction", "ancestors", "--root", root]);
		expect(result.status).toBe(0);
		expect(result.stdout).toContain('Slice of "mod-a" (ancestors, depth 1):');
		expect(result.stdout).toContain("goal [goal-and-requirements] — 目标 (goal.md)");
		expect(result.stdout).toContain("nodes (2):");
		expect(result.stdout).toContain("mod-a --parent--> goal");
	});

	test("neighbors 沿指定边双向展开", () => {
		const root = makeFixtureRepo();
		const result = runCli([
			"graph",
			"mod-b",
			"--direction",
			"neighbors",
			"--edge",
			"depends-on",
			"--root",
			root,
		]);
		expect(result.status).toBe(0);
		expect(result.stdout).toContain('Slice of "mod-b" (neighbors, depth 1):');
		expect(result.stdout).toContain("mod-a [module-design] — A 模块 (mods/a/SPEC.md)");
		expect(result.stdout).toContain("mod-a --depends-on--> mod-b");
	});

	test("--json 与源 GraphSlice 逐字段一致", () => {
		const root = makeFixtureRepo();
		const result = runCli([
			"graph",
			"mod-b",
			"--direction",
			"neighbors",
			"--edge",
			"depends-on",
			"--json",
			"--root",
			root,
		]);
		expect(result.status).toBe(0);
		expect(JSON.parse(result.stdout)).toEqual({
			root: "mod-b",
			direction: "neighbors",
			nodes: [
				{
					id: "mod-b",
					type: "module-design",
					path: "mods/b/SPEC.md",
					frontmatter: { id: "mod-b", type: "module-design", parent: "goal" },
				},
				{
					id: "mod-a",
					type: "module-design",
					title: "A 模块",
					path: "mods/a/SPEC.md",
					frontmatter: {
						id: "mod-a",
						type: "module-design",
						title: "A 模块",
						parent: "goal",
						"depends-on": ["mod-b"],
						tags: ["core"],
					},
				},
			],
			edges: [{ from: "mod-a", to: "mod-b", kind: "depends-on" }],
			missing: [],
		});
	});

	test("未知 id 返回 2", () => {
		const root = makeFixtureRepo();
		const result = runCli(["graph", "missing", "--direction", "subtree", "--root", root]);
		expect(result.status).toBe(2);
		expect(result.stderr).toContain('No spec with id "missing".');
	});

	test("--direction 非法返回 2", () => {
		const root = makeFixtureRepo();
		const result = runCli(["graph", "goal", "--direction", "bogus", "--root", root]);
		expect(result.status).toBe(2);
		expect(result.stderr).toContain("--direction must be one of");
	});

	test("缺少 --direction 返回 2", () => {
		const root = makeFixtureRepo();
		expect(runCli(["graph", "goal", "--root", root]).status).toBe(2);
	});

	test("--edge 非法返回 2", () => {
		const root = makeFixtureRepo();
		const result = runCli([
			"graph",
			"goal",
			"--direction",
			"neighbors",
			"--edge",
			"bogus",
			"--root",
			root,
		]);
		expect(result.status).toBe(2);
		expect(result.stderr).toContain("--edge must be one of");
	});

	test("--depth 非数字返回 2", () => {
		const root = makeFixtureRepo();
		const result = runCli([
			"graph",
			"goal",
			"--direction",
			"subtree",
			"--depth",
			"x",
			"--root",
			root,
		]);
		expect(result.status).toBe(2);
		expect(result.stderr).toContain("--depth");
	});
});
