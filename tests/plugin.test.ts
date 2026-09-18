import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import {
	cpSync,
	existsSync,
	mkdirSync,
	mkdtempSync,
	readdirSync,
	readFileSync,
	rmSync,
	symlinkSync,
	writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { delimiter, join, resolve } from "node:path";
import { makeFixtureRepo } from "./helpers.ts";

const ROOT = join(import.meta.dir, "..");
const TEMP = mkdtempSync(join(tmpdir(), "specrail-plugin-"));
const PLUGIN = join(TEMP, "plugin cache with spaces", "specrail");
const TOOLS = join(TEMP, "tools");
const PACKAGE = JSON.parse(readFileSync(join(ROOT, "package.json"), "utf8"));
const WINDOWS = process.platform === "win32";
const SHELL = WINDOWS ? (process.env.ComSpec ?? "C:\\Windows\\System32\\cmd.exe") : "/bin/sh";
const INITIAL_TEMP_FILES = readdirSync(ROOT)
	.filter((file) => file.endsWith(".bun-build"))
	.sort();

function run(args: string[], cwd: string, env: NodeJS.ProcessEnv = {}) {
	return spawnSync(
		SHELL,
		WINDOWS
			? ["/d", "/c", "specrail.cmd", ...args]
			: ["-c", 'exec specrail "$@"', "specrail", ...args],
		{
			cwd,
			encoding: "utf8",
			env: { ...process.env, PATH: `${join(PLUGIN, "bin")}${delimiter}${TOOLS}`, ...env },
		},
	);
}

beforeAll(() => {
	const build = spawnSync(
		process.execPath,
		["run", "build:plugin", "--current", "--outdir", PLUGIN],
		{ cwd: ROOT, encoding: "utf8", timeout: 120_000 },
	);
	expect(build.status, build.stdout + build.stderr).toBe(0);
	mkdirSync(TOOLS);
	if (!WINDOWS) {
		const uname = Bun.which("uname");
		if (!uname) throw new Error("Plugin shell tests require uname");
		symlinkSync(uname, join(TOOLS, "uname"));
	}
}, 120_000);

afterAll(() => rmSync(TEMP, { recursive: true, force: true }));

describe("可分发市场插件", () => {
	test("构建不在源码目录留下 Bun 临时可执行文件", () => {
		expect(
			readdirSync(ROOT)
				.filter((file) => file.endsWith(".bun-build"))
				.sort(),
		).toEqual(INITIAL_TEMP_FILES);
	});

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
			for (const file of readdirSync(join(ROOT, "skills", name), {
				recursive: true,
				encoding: "utf8",
			})) {
				if (!file.endsWith(".md")) continue;
				expect(readFileSync(join(PLUGIN, "skills", name, file))).toEqual(
					readFileSync(join(ROOT, "skills", name, file)),
				);
			}
		}
		for (const path of ["node_modules", "src", ".git", ".qoder", "package.json", "bun.lock"]) {
			expect(existsSync(join(PLUGIN, path))).toBe(false);
		}
		for (const path of [
			"README.md",
			"LICENSE",
			"NOTICE",
			"licenses/yaml-LICENSE",
			"licenses/bun-1.4.2.txt",
		]) {
			expect(existsSync(join(PLUGIN, path)), path).toBe(true);
		}
	});

	test("仓库市场直接定位已随 Git 分发的完整插件", async () => {
		for (const assistant of ["claude", "qoder"]) {
			const market = JSON.parse(
				readFileSync(join(ROOT, `.${assistant}-plugin/marketplace.json`), "utf8"),
			);
			const source = resolve(ROOT, market.plugins[0].source);
			expect(source).toBe(join(ROOT, "plugins/specrail"));
			const manifest = JSON.parse(
				readFileSync(join(source, `.${assistant}-plugin/plugin.json`), "utf8"),
			);
			expect(manifest.version).toBe(PACKAGE.version);
			for (const path of ["package.json", "bun.lock", "node_modules"]) {
				expect(existsSync(join(source, path))).toBe(false);
			}
		}
		const source = join(ROOT, "plugins/specrail");
		for (const [target, magic] of [
			["darwin-arm64", "cffaedfe"],
			["darwin-x64", "cffaedfe"],
			["linux-arm64", "7f454c46"],
			["linux-x64", "7f454c46"],
			["windows-arm64.exe", "4d5a"],
			["windows-x64.exe", "4d5a"],
		] as const) {
			const header = await Bun.file(join(source, "libexec", `specrail-${target}`))
				.slice(0, magic.length / 2)
				.arrayBuffer();
			expect(Buffer.from(header).toString("hex")).toBe(magic);
		}
		const result = run(["--version"], TEMP, { PATH: `${join(source, "bin")}${delimiter}${TOOLS}` });
		expect(result.status, result.stderr).toBe(0);
		expect(result.stdout.trim()).toBe(PACKAGE.version);
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
			writeFileSync(
				join(TOOLS, `${binary}${WINDOWS ? ".cmd" : ""}`),
				WINDOWS ? "@exit /b 97\r\n" : "#!/bin/sh\nexit 97\n",
				{ mode: 0o755 },
			);
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
			[
				"create",
				"my spec.md",
				"--id",
				"goal",
				"--type",
				"goal-and-requirements",
				"--title",
				"My goal",
			],
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

	test.skipIf(WINDOWS)("不支持的平台明确失败，不回退系统 Node 或下载运行时", () => {
		const tools = join(TEMP, "unsupported platform");
		mkdirSync(tools);
		writeFileSync(join(tools, "uname"), "#!/bin/sh\nprintf '%s\\n' unsupported\n", { mode: 0o755 });
		const result = run(["--version"], TEMP, { PATH: `${join(PLUGIN, "bin")}:${tools}` });
		expect(result.status).toBe(2);
		expect(result.stderr).toContain("Unsupported platform");
	});

	test.skipIf(!WINDOWS)("Windows 原生启动器拒绝不支持的架构", () => {
		const result = run(["--version"], TEMP, {
			PROCESSOR_ARCHITECTURE: "x86",
			PROCESSOR_ARCHITEW6432: "",
		});
		expect(result.status).toBe(2);
		expect(result.stderr).toContain("Unsupported platform");
	});

	test("插件缺少当前平台产物时明确失败", () => {
		const incomplete = join(TEMP, "incomplete");
		cpSync(join(PLUGIN, "bin"), join(incomplete, "bin"), { recursive: true });
		const result = run(["--version"], TEMP, {
			PATH: `${join(incomplete, "bin")}${delimiter}${TOOLS}`,
		});
		expect(result.status).toBe(2);
		expect(result.stderr).toContain("Missing bundled CLI");
	});

	test.skipIf(WINDOWS).each([
		["Darwin", "arm64", "darwin-arm64"],
		["Darwin", "x86_64", "darwin-x64"],
		["Linux", "aarch64", "linux-arm64"],
		["Linux", "x86_64", "linux-x64"],
		["MINGW64_NT", "x86_64", "windows-x64.exe"],
		["MSYS_NT", "aarch64", "windows-arm64.exe"],
	])("启动器为 %s %s 选择对应运行时", (os, arch, target) => {
		const root = join(TEMP, target);
		const tools = join(root, "tools");
		mkdirSync(tools, { recursive: true });
		mkdirSync(join(root, "libexec"));
		cpSync(join(PLUGIN, "bin"), join(root, "bin"), { recursive: true });
		writeFileSync(
			join(tools, "uname"),
			`#!/bin/sh\ncase "$1" in -s) printf '%s' '${os}';; -m) printf '%s' '${arch}';; esac\n`,
			{ mode: 0o755 },
		);
		writeFileSync(
			join(root, "libexec", `specrail-${target}`),
			'#!/bin/sh\nprintf "%s\\n" "$@"\nexit 17\n',
			{ mode: 0o755 },
		);
		const result = run(["argument with spaces", "--flag"], TEMP, {
			PATH: `${join(root, "bin")}:${tools}`,
		});
		expect(result.status).toBe(17);
		expect(result.stdout).toBe("argument with spaces\n--flag\n");
	});

	test("重复构建清除旧技能和非发布文件", () => {
		mkdirSync(join(PLUGIN, "skills/specrail-obsolete"));
		writeFileSync(join(PLUGIN, "skills/specrail-obsolete/SKILL.md"), "obsolete");
		writeFileSync(join(PLUGIN, "settings.local.json"), "{}");
		const build = spawnSync(
			process.execPath,
			["run", "build:plugin", "--current", "--outdir", PLUGIN],
			{
				cwd: ROOT,
				encoding: "utf8",
				timeout: 120_000,
			},
		);
		expect(build.status, build.stderr).toBe(0);
		expect(existsSync(join(PLUGIN, "skills/specrail-obsolete"))).toBe(false);
		expect(existsSync(join(PLUGIN, "settings.local.json"))).toBe(false);
		expect(run(["--version"], TEMP).stdout.trim()).toBe(PACKAGE.version);
	}, 120_000);

	test("拒绝覆盖非构建输出目录", () => {
		const output = join(TEMP, "user directory");
		mkdirSync(output);
		writeFileSync(join(output, "keep.txt"), "user content");
		const build = spawnSync(
			process.execPath,
			["run", "build:plugin", "--current", "--outdir", output],
			{
				cwd: ROOT,
				encoding: "utf8",
				timeout: 120_000,
			},
		);
		expect(build.status).not.toBe(0);
		expect(readFileSync(join(output, "keep.txt"), "utf8")).toBe("user content");
		expect(existsSync(join(output, "libexec"))).toBe(false);
	}, 120_000);
});
