import { describe, expect, test } from "bun:test";
import { existsSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { makeFixtureRepo, runCli, runCliInPty } from "./helpers.ts";

describe("create", () => {
	test("写出 frontmatter 与类型骨架", () => {
		const root = makeFixtureRepo();
		const result = runCli([
			"create",
			"mods/c/SPEC.md",
			"--id",
			"mod-c",
			"--type",
			"module-design",
			"--title",
			"C 模块",
			"--root",
			root,
		]);
		expect(result.status).toBe(0);
		expect(result.stdout).toContain("Created mods/c/SPEC.md (id: mod-c).");
		const content = readFileSync(join(root, "mods/c/SPEC.md"), "utf8");
		expect(content.startsWith("---\nid: mod-c\ntype: module-design\n")).toBe(true);
		expect(content).toContain("title: C 模块");
		expect(content).toContain("## Responsibility");
		expect(content).toContain("## Boundary");
	});

	test("可重复的链接与元数据参数", () => {
		const root = makeFixtureRepo();
		const result = runCli([
			"create",
			"specs/d.md",
			"--id",
			"d",
			"--type",
			"task-spec",
			"--title",
			"D",
			"--status",
			"draft",
			"--parent",
			"goal",
			"--depends-on",
			"mod-b",
			"--depends-on",
			"mod-a",
			"--references",
			"mod-a",
			"--implements",
			"mod-b",
			"--covers",
			"widget",
			"--tags",
			"x",
			"--tags",
			"y",
			"--root",
			root,
		]);
		expect(result.status).toBe(0);
		const content = readFileSync(join(root, "specs/d.md"), "utf8");
		expect(content).toContain("status: draft");
		expect(content).toContain("parent: goal");
		expect(content).toContain("depends-on: [mod-b, mod-a]");
		expect(content).toContain("references: [mod-a]");
		expect(content).toContain("implements: [mod-b]");
		expect(content).toContain("covers: [widget]");
		expect(content).toContain("tags: [x, y]");
		expect(content).toContain("## Purpose");
	});

	test("--json 输出 {path,id}", () => {
		const root = makeFixtureRepo();
		const result = runCli([
			"create",
			"mods/c/SPEC.md",
			"--id",
			"mod-c",
			"--type",
			"module-design",
			"--title",
			"C",
			"--json",
			"--root",
			root,
		]);
		expect(result.status).toBe(0);
		expect(JSON.parse(result.stdout)).toEqual({ path: "mods/c/SPEC.md", id: "mod-c" });
	});

	test("重复 id 返回 2 且不写文件", () => {
		const root = makeFixtureRepo();
		const result = runCli([
			"create",
			"mods/c/SPEC.md",
			"--id",
			"mod-a",
			"--type",
			"module-design",
			"--title",
			"C",
			"--root",
			root,
		]);
		expect(result.status).toBe(2);
		expect(result.stderr).toContain('Spec id "mod-a" is already in use.');
		expect(existsSync(join(root, "mods/c/SPEC.md"))).toBe(false);
	});

	test("已存在的路径返回 2", () => {
		const root = makeFixtureRepo();
		const result = runCli([
			"create",
			"mods/a/SPEC.md",
			"--id",
			"mod-c",
			"--type",
			"module-design",
			"--title",
			"C",
			"--root",
			root,
		]);
		expect(result.status).toBe(2);
		expect(result.stderr).toContain("File already exists: mods/a/SPEC.md");
	});

	test("非法 --type 返回 2", () => {
		const root = makeFixtureRepo();
		const result = runCli([
			"create",
			"mods/c/SPEC.md",
			"--id",
			"mod-c",
			"--type",
			"bogus",
			"--title",
			"C",
			"--root",
			root,
		]);
		expect(result.status).toBe(2);
		expect(result.stderr).toContain("--type must be one of");
	});

	test("非法 --status 返回 2", () => {
		const root = makeFixtureRepo();
		const result = runCli([
			"create",
			"mods/c/SPEC.md",
			"--id",
			"mod-c",
			"--type",
			"module-design",
			"--title",
			"C",
			"--status",
			"bogus",
			"--root",
			root,
		]);
		expect(result.status).toBe(2);
		expect(result.stderr).toContain("--status must be one of");
	});

	test("缺少必填参数返回 2", () => {
		const root = makeFixtureRepo();
		expect(
			runCli([
				"create",
				"mods/c/SPEC.md",
				"--type",
				"module-design",
				"--title",
				"C",
				"--root",
				root,
			]).status,
		).toBe(2);
		expect(
			runCli([
				"create",
				"mods/c/SPEC.md",
				"--id",
				"mod-c",
				"--type",
				"module-design",
				"--root",
				root,
			]).status,
		).toBe(2);
	});

	test("拒绝越出根目录的路径", () => {
		const root = makeFixtureRepo();
		const result = runCli([
			"create",
			"../escape.md",
			"--id",
			"escape",
			"--type",
			"module-design",
			"--title",
			"E",
			"--root",
			root,
		]);
		expect(result.status).toBe(2);
		expect(result.stderr).toContain("Path must stay inside the project root");
	});

	test("拒绝非 .md 路径", () => {
		const root = makeFixtureRepo();
		const result = runCli([
			"create",
			"mods/c/spec.txt",
			"--id",
			"mod-c",
			"--type",
			"module-design",
			"--title",
			"C",
			"--root",
			root,
		]);
		expect(result.status).toBe(2);
		expect(result.stderr).toContain("Spec files must end in .md");
	});
});

describe("update", () => {
	test("--set 与 --add-list 只改 frontmatter，正文原样", () => {
		const root = makeFixtureRepo();
		expect(
			runCli([
				"create",
				"mods/c/SPEC.md",
				"--id",
				"mod-c",
				"--type",
				"module-design",
				"--title",
				"C",
				"--root",
				root,
			]).status,
		).toBe(0);
		const result = runCli([
			"update",
			"mod-c",
			"--set",
			"status=active",
			"--add-list",
			"tags=x",
			"--add-list",
			"tags=y",
			"--root",
			root,
		]);
		expect(result.status).toBe(0);
		expect(result.stdout).toContain("Updated frontmatter of mods/c/SPEC.md (id: mod-c).");
		const content = readFileSync(join(root, "mods/c/SPEC.md"), "utf8");
		expect(content).toContain("status: active");
		expect(content).toContain("tags: [x, y]");
		expect(content.endsWith("\n## Responsibility\n\n## Boundary\n")).toBe(true);
	});

	test("--add-list 与已有列表项合并", () => {
		const root = makeFixtureRepo();
		const result = runCli(["update", "mod-a", "--add-list", "tags=extra", "--root", root]);
		expect(result.status).toBe(0);
		const content = readFileSync(join(root, "mods/a/SPEC.md"), "utf8");
		expect(content).toContain("tags: [core, extra]");
		expect(content).toContain("depends-on: [mod-b]");
	});

	test("--remove 删除整个字段", () => {
		const root = makeFixtureRepo();
		const result = runCli(["update", "mod-a", "--remove", "tags", "--root", root]);
		expect(result.status).toBe(0);
		const content = readFileSync(join(root, "mods/a/SPEC.md"), "utf8");
		expect(content).not.toContain("tags");
		expect(content).toContain("depends-on: [mod-b]");
		expect(content.endsWith("\n## Responsibility\nwidget rendering\n")).toBe(true);
	});

	test("--remove-list 删除列表项，空列表时删除字段", () => {
		const root = makeFixtureRepo();
		const result = runCli(["update", "mod-a", "--remove-list", "depends-on=mod-b", "--root", root]);
		expect(result.status).toBe(0);
		const content = readFileSync(join(root, "mods/a/SPEC.md"), "utf8");
		expect(content).not.toContain("depends-on");
		expect(content).toContain("tags: [core]");
	});

	test("--json 输出 {id,path}", () => {
		const root = makeFixtureRepo();
		const result = runCli(["update", "mod-a", "--set", "status=active", "--json", "--root", root]);
		expect(result.status).toBe(0);
		expect(JSON.parse(result.stdout)).toEqual({ id: "mod-a", path: "mods/a/SPEC.md" });
	});

	test("--add-list 未知字段返回 2", () => {
		const root = makeFixtureRepo();
		const before = readFileSync(join(root, "mods/a/SPEC.md"), "utf8");
		const result = runCli(["update", "mod-a", "--add-list", "title=x", "--root", root]);
		expect(result.status).toBe(2);
		expect(result.stderr).toContain("--add-list supports only");
		expect(readFileSync(join(root, "mods/a/SPEC.md"), "utf8")).toBe(before);
	});

	test("--set 列表字段返回 2（交由 add-list/remove-list）", () => {
		const root = makeFixtureRepo();
		const result = runCli(["update", "mod-a", "--set", "tags=x", "--root", root]);
		expect(result.status).toBe(2);
		expect(result.stderr).toContain("Use addList/removeList");
	});

	test("--set 缺少 = 返回 2", () => {
		const root = makeFixtureRepo();
		const result = runCli(["update", "mod-a", "--set", "status", "--root", root]);
		expect(result.status).toBe(2);
		expect(result.stderr).toContain("--set expects K=V");
	});

	test("未知 id 返回 2", () => {
		const root = makeFixtureRepo();
		const result = runCli(["update", "missing", "--set", "status=active", "--root", root]);
		expect(result.status).toBe(2);
		expect(result.stderr).toContain('No spec with id "missing".');
	});
});

describe("delete", () => {
	test("--yes 删除文件", () => {
		const root = makeFixtureRepo();
		const result = runCli(["delete", "mod-b", "--yes", "--root", root]);
		expect(result.status).toBe(0);
		expect(result.stdout).toContain("Deleted mods/b/SPEC.md (id: mod-b).");
		expect(existsSync(join(root, "mods/b/SPEC.md"))).toBe(false);
	});

	test("--json 输出 {id,path}", () => {
		const root = makeFixtureRepo();
		const result = runCli(["delete", "mod-b", "--yes", "--json", "--root", root]);
		expect(result.status).toBe(0);
		expect(JSON.parse(result.stdout)).toEqual({ id: "mod-b", path: "mods/b/SPEC.md" });
	});

	test("无 --yes 且非交互时拒绝且不删除", () => {
		const root = makeFixtureRepo();
		const result = runCli(["delete", "mod-b", "--root", root]);
		expect(result.status).toBe(2);
		expect(result.stderr).toContain("Refusing to delete without --yes (non-interactive).");
		expect(existsSync(join(root, "mods/b/SPEC.md"))).toBe(true);
	});

	test("未知 id 返回 2", () => {
		const root = makeFixtureRepo();
		const result = runCli(["delete", "missing", "--yes", "--root", root]);
		expect(result.status).toBe(2);
		expect(result.stderr).toContain('No spec with id "missing".');
	});

	test("缺少 id 参数返回 2", () => {
		const root = makeFixtureRepo();
		expect(runCli(["delete", "--yes", "--root", root]).status).toBe(2);
	});

	test("交互确认 y 删除文件", async () => {
		const root = makeFixtureRepo();
		const result = await runCliInPty(["delete", "mod-b", "--root", root], "y\n");
		expect(result.status).toBe(0);
		expect(existsSync(join(root, "mods/b/SPEC.md"))).toBe(false);
	});

	test("交互确认 n 保留文件并返回 0", async () => {
		const root = makeFixtureRepo();
		const result = await runCliInPty(["delete", "mod-b", "--root", root], "n\n");
		expect(result.status).toBe(0);
		expect(existsSync(join(root, "mods/b/SPEC.md"))).toBe(true);
	});

	test("交互提示 Ctrl+D 返回 0 且保留文件", async () => {
		const root = makeFixtureRepo();
		const result = await runCliInPty(["delete", "mod-b", "--root", root], "\x04");
		expect(result.status).toBe(0);
		expect(result.output).not.toContain("AbortError");
		expect(existsSync(join(root, "mods/b/SPEC.md"))).toBe(true);
	});

	test("交互提示 Ctrl+C 返回 0 且保留文件", async () => {
		const root = makeFixtureRepo();
		const result = await runCliInPty(["delete", "mod-b", "--root", root], "\x03");
		expect(result.status).toBe(0);
		expect(result.output).not.toContain("AbortError");
		expect(existsSync(join(root, "mods/b/SPEC.md"))).toBe(true);
	});
});

describe("validate", () => {
	test("无发现返回 0", () => {
		const root = makeFixtureRepo();
		const result = runCli(["validate", "--root", root]);
		expect(result.status).toBe(0);
		expect(result.stdout.trimEnd()).toBe("Spec-graph is valid: no issues found.");
	});

	test("悬空链接返回 1 并报告 Dangling links", () => {
		const root = makeFixtureRepo();
		rmSync(join(root, "mods/b/SPEC.md"));
		const result = runCli(["validate", "--root", root]);
		expect(result.status).toBe(1);
		expect(result.stdout).toContain("Dangling links (1):");
		expect(result.stdout).toContain("mod-a (mods/a/SPEC.md) --depends-on--> mod-b [missing]");
	});

	test("重复 id 返回 1 并报告 Duplicate ids", () => {
		const root = makeFixtureRepo();
		writeFileSync(
			join(root, "mods/a/copy.md"),
			"---\nid: mod-a\ntype: module-design\ntitle: copy\n---\n",
			"utf8",
		);
		const result = runCli(["validate", "--root", root]);
		expect(result.status).toBe(1);
		expect(result.stdout).toContain("Duplicate ids (1):");
		expect(result.stdout).toContain("mod-a: mods/a/SPEC.md, mods/a/copy.md");
	});

	test("parent 环返回 1 并报告 Parent cycles", () => {
		const root = makeFixtureRepo();
		writeFileSync(
			join(root, "ring1.md"),
			"---\nid: ring-1\ntype: task-spec\nparent: ring-2\n---\n",
			"utf8",
		);
		writeFileSync(
			join(root, "ring2.md"),
			"---\nid: ring-2\ntype: task-spec\nparent: ring-1\n---\n",
			"utf8",
		);
		const result = runCli(["validate", "--root", root]);
		expect(result.status).toBe(1);
		expect(result.stdout).toContain("Parent cycles (1):");
	});

	test("--json 输出 ValidationReport", () => {
		const root = makeFixtureRepo();
		rmSync(join(root, "mods/b/SPEC.md"));
		const result = runCli(["validate", "--json", "--root", root]);
		expect(result.status).toBe(1);
		expect(JSON.parse(result.stdout)).toEqual({
			danglingLinks: [
				{ from: "mod-a", fromPath: "mods/a/SPEC.md", kind: "depends-on", target: "mod-b" },
			],
			duplicateIds: [],
			parentCycles: [],
		});
	});

	test("--json 无发现时输出空报告并返回 0", () => {
		const root = makeFixtureRepo();
		const result = runCli(["validate", "--json", "--root", root]);
		expect(result.status).toBe(0);
		expect(JSON.parse(result.stdout)).toEqual({
			danglingLinks: [],
			duplicateIds: [],
			parentCycles: [],
		});
	});
});
