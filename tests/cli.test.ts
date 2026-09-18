import { describe, expect, test } from "bun:test";
import { join } from "node:path";
import { makeFixtureRepo, runCli } from "./helpers.ts";

describe("cli 入口", () => {
	test("--version 输出版本并返回 0", () => {
		const result = runCli(["--version"]);
		expect(result.status).toBe(0);
		expect(result.stdout.trim()).toMatch(/^\d+\.\d+\.\d+$/);
	});

	test("-v 与 --version 等价", () => {
		expect(runCli(["-v"]).stdout).toBe(runCli(["--version"]).stdout);
	});

	test("--help 返回 0 并列出命令", () => {
		const result = runCli(["--help"]);
		expect(result.status).toBe(0);
		expect(result.stdout).toContain("validate");
		for (const name of ["list", "show", "grep", "graph", "create", "update", "delete"]) {
			expect(result.stdout).toContain(name);
		}
	});

	test("无参数时打印帮助并返回 0", () => {
		const result = runCli([]);
		expect(result.status).toBe(0);
		expect(result.stdout).toContain("specrail");
	});

	test("未知命令返回 2 且 stderr 有提示", () => {
		const result = runCli(["nope"]);
		expect(result.status).toBe(2);
		expect(result.stderr).toContain("Unknown command");
	});

	test("未知参数返回 2", () => {
		const result = runCli(["list", "--bogus"]);
		expect(result.status).toBe(2);
	});

	test("子命令的 --help 打印帮助且不执行命令", () => {
		const root = makeFixtureRepo();
		const result = runCli(["list", "--help", "--root", root]);
		expect(result.status).toBe(0);
		expect(result.stdout).toContain("validate");
		expect(result.stdout).not.toContain("mod-a");
	});

	test("子命令的 -h 与 --help 等价", () => {
		expect(runCli(["show", "-h"]).stdout).toBe(runCli(["--help"]).stdout);
	});

	test("子命令的 -v 与 --version 输出版本并返回 0", () => {
		const result = runCli(["validate", "--version"]);
		expect(result.status).toBe(0);
		expect(result.stdout.trim()).toMatch(/^\d+\.\d+\.\d+$/);
		expect(runCli(["validate", "-v"]).stdout).toBe(result.stdout);
	});

	test("不存在的 --root 返回 2", () => {
		const root = makeFixtureRepo();
		const missing = join(root, "missing");
		const result = runCli(["list", "--root", missing]);
		expect(result.status).toBe(2);
		expect(result.stderr).toContain(`Root directory does not exist: ${missing}`);
	});

	test("--root 指向文件返回 2", () => {
		const root = makeFixtureRepo();
		const result = runCli(["validate", "--root", join(root, "goal.md")]);
		expect(result.status).toBe(2);
		expect(result.stderr).toContain("Root is not a directory");
	});
});
