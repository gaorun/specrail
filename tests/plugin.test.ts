import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import {
	cpSync,
	existsSync,
	mkdirSync,
	mkdtempSync,
	readFileSync,
	readdirSync,
	rmSync,
	symlinkSync,
	writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { makeFixtureRepo } from "./helpers.ts";

const ROOT = join(import.meta.dir, "..");
const TEMP = mkdtempSync(join(tmpdir(), "specrail-plugin-"));
const PLUGIN = join(TEMP, "plugin cache with spaces", "specrail");
const TOOLS = join(TEMP, "tools");
const PACKAGE = JSON.parse(readFileSync(join(ROOT, "package.json"), "utf8"));
const SHELL = process.platform === "win32" ? "bash" : "/bin/sh";

function run(args: string[], cwd: string, env: NodeJS.ProcessEnv = {}) {
	return spawnSync(SHELL, ["-c", 'exec specrail "$@"', "specrail", ...args], {
		cwd,
		encoding: "utf8",
		env: { ...process.env, PATH: `${join(PLUGIN, "bin")}:${TOOLS}`, ...env },
	});
}

beforeAll(() => {
	const build = spawnSync(
		process.execPath,
		["run", "build:plugin", "--current", "--outdir", PLUGIN],
		{ cwd: ROOT, encoding: "utf8", timeout: 120_000 },
	);
	expect(build.status, build.stdout + build.stderr).toBe(0);
	mkdirSync(TOOLS);
	const uname = Bun.which("uname");
	if (!uname) throw new Error("Plugin shell tests require uname");
	symlinkSync(uname, join(TOOLS, "uname"));
}, 120_000);

afterAll(() => rmSync(TEMP, { recursive: true, force: true }));

describe("可分发市场插件", () => {
	test("两端市场入口指向完整插件，版本与 CLI 一致", () => {
		for (const assistant of ["claude", "qoder"]) {
			const market = JSON.parse(
				readFileSync(join(PLUGIN, `.${assistant}-plugin/marketplace.json`), "utf8"),
			);
			expect(market.name).toBe("specrail-marketplace");
			const entry = market.plugins.find((plugin: { name: string }) => plugin.name === "specrail");
			expect(entry).toBeDefined();
			const source = resolve(PLUGIN, entry.source);
			expect(source).toBe(PLUGIN);
			const manifest = JSON.parse(
				readFileSync(join(source, `.${assistant}-plugin/plugin.json`), "utf8"),
			);
			expect(manifest.name).toBe("specrail");
			expect(manifest.version).toBe(PACKAGE.version);
			expect(existsSync(join(source, "bin/specrail"))).toBe(true);
		}
	});

	test("复制技能及兄弟文件，不携带构建依赖、配置或源码", () => {
		const skills = readdirSync(join(PLUGIN, "skills"));
		expect(skills).toHaveLength(10);
		for (const name of skills) {
			for (const file of readdirSync(join(ROOT, "skills", name), { recursive: true })) {
				if (!String(file).endsWith(".md")) continue;
				expect(readFileSync(join(PLUGIN, "skills", name, file))).toEqual(
					readFileSync(join(ROOT, "skills", name, file)),
				);
			}
		}
		for (const path of ["node_modules", "src", ".git", ".qoder", "package.json", "bun.lock"]) {
			expect(existsSync(join(PLUGIN, path))).toBe(false);
		}
		for (const path of ["README.md", "LICENSE", "NOTICE"]) {
			expect(existsSync(join(PLUGIN, path))).toBe(true);
		}
	});

	test("没有 node/bun 且缓存路径含空格时可直接执行", () => {
		const result = run(["--version"], TEMP);
		expect(result.status, result.stderr).toBe(0);
		expect(result.stdout.trim()).toBe(PACKAGE.version);
	});

	test("忽略版本管理器 shim 和宿主运行时选项，不加载项目 bunfig", () => {
		const project = join(TEMP, "project");
		mkdirSync(project);
		for (const binary of ["node", "bun", "nvm", "mise", "n"]) {
			writeFileSync(join(TOOLS, binary), "#!/bin/sh\nexit 97\n", { mode: 0o755 });
		}
		writeFileSync(join(project, ".nvmrc"), "v12.0.0\n");
		writeFileSync(join(project, ".node-version"), "14.0.0\n");
		writeFileSync(join(project, "mise.toml"), '[tools]\nnode = "18"\n');
		writeFileSync(join(project, "bunfig.toml"), 'preload = ["./preload.js"]\n');
		writeFileSync(join(project, "preload.js"), 'throw new Error("Project preload executed");\n');
		const result = run(["--version"], project, {
			NODE_OPTIONS: "--invalid-node-option",
			BUN_OPTIONS: "--preload ./preload.js",
			BUN_BE_BUN: "1",
		});
		expect(result.status, result.stderr).toBe(0);
		expect(result.stdout.trim()).toBe(PACKAGE.version);
	});

	test("保留项目 cwd 和含空格的参数，支持图读写", () => {
		const project = join(TEMP, "graph project");
		mkdirSync(project);
		const created = run(
			["create", "my spec.md", "--id", "goal", "--type", "goal-and-requirements", "--title", "My goal"],
			project,
		);
		expect(created.status, created.stderr).toBe(0);
		expect(existsSync(join(project, "my spec.md"))).toBe(true);
		expect(existsSync(join(PLUGIN, "my spec.md"))).toBe(false);
		const listed = run(["list", "--json"], project);
		expect(listed.status, listed.stderr).toBe(0);
		expect(JSON.parse(listed.stdout)).toEqual([
			{ id: "goal", type: "goal-and-requirements", title: "My goal", path: "my spec.md" },
		]);
		expect(run(["update", "goal", "--set", "title=Updated goal"], project).status).toBe(0);
		expect(readFileSync(join(project, "my spec.md"), "utf8")).toContain("Updated goal");
		expect(run(["validate"], project).status).toBe(0);
	});

	test("内置技能源支持 init/sync，不依赖源码仓库位置", () => {
		const project = join(TEMP, "init project");
		mkdirSync(project);
		const initialized = run(["init", "--tools", "qoder,claude", "--rule"], project);
		expect(initialized.status, initialized.stderr).toBe(0);
		expect(readdirSync(join(project, ".qoder/skills"))).toHaveLength(10);
		expect(readdirSync(join(project, ".claude/skills"))).toHaveLength(10);
		expect(readFileSync(join(project, "AGENTS.md"), "utf8")).toContain("specrail:rule:begin");
		expect(run(["sync"], project).status).toBe(0);
	});

	test("透传 CLI 成功、校验失败和用法错误退出码", () => {
		const fixture = makeFixtureRepo();
		const project = join(TEMP, "exit codes");
		cpSync(fixture, project, { recursive: true });
		rmSync(fixture, { recursive: true });
		expect(run(["validate"], project).status).toBe(0);
		rmSync(join(project, "mods/b/SPEC.md"));
		expect(run(["validate"], project).status).toBe(1);
		expect(run(["nope"], project).status).toBe(2);
	});

	test("不支持的平台明确失败，不回退系统 Node 或下载运行时", () => {
		const tools = join(TEMP, "unsupported platform");
		mkdirSync(tools);
		writeFileSync(join(tools, "uname"), "#!/bin/sh\nprintf '%s\\n' unsupported\n", { mode: 0o755 });
		const result = run(["--version"], TEMP, { PATH: `${join(PLUGIN, "bin")}:${tools}` });
		expect(result.status).toBe(2);
		expect(result.stderr).toContain("Unsupported platform");
	});
});
