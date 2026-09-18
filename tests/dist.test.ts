import { beforeAll, describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { makeFixtureRepo } from "./helpers.ts";

const ROOT = join(import.meta.dir, "..");
const CLI = join(ROOT, "dist", "cli.js");

interface NodeRun {
	status: number | null;
	stdout: string;
	stderr: string;
}

function runNode(args: string[]): NodeRun {
	const result = spawnSync("node", [CLI, ...args], { cwd: ROOT, encoding: "utf8" });
	return { status: result.status, stdout: result.stdout, stderr: result.stderr };
}

beforeAll(() => {
	const build = spawnSync("bun", ["run", "build"], { cwd: ROOT, encoding: "utf8" });
	if (build.status !== 0) throw new Error(`bun run build failed:\n${build.stderr}`);
});

describe("dist/cli.js 在 node 下", () => {
	test("构建产物以 node shebang 开头", () => {
		expect(readFileSync(CLI, "utf8").startsWith("#!/usr/bin/env node")).toBe(true);
	});

	test("--version 返回 0 与版本号", () => {
		const result = runNode(["--version"]);
		expect(result.status).toBe(0);
		expect(result.stdout.trim()).toMatch(/^\d+\.\d+\.\d+$/);
	});

	test("list --json 对 fixture 返回全部节点", () => {
		const root = makeFixtureRepo();
		const result = runNode(["list", "--root", root, "--json"]);
		expect(result.status).toBe(0);
		expect(JSON.parse(result.stdout)).toHaveLength(3);
	});

	test("退出码契约在构建产物内成立", () => {
		const unknown = runNode(["nope"]);
		expect(unknown.status).toBe(2);
		expect(unknown.stderr).toContain("Unknown command");

		const root = makeFixtureRepo();
		expect(runNode(["validate", "--root", root]).status).toBe(0);
		rmSync(join(root, "mods", "b", "SPEC.md"));
		const broken = runNode(["validate", "--root", root]);
		expect(broken.status).toBe(1);
		expect(broken.stdout).toContain("Dangling links (1):");
	});

	test("npm 包不携带原生插件产物和本地安装验证配置", () => {
		const root = mkdtempSync(join(tmpdir(), "specrail-pack-"));
		try {
			writeFileSync(join(root, "package.json"), readFileSync(join(ROOT, "package.json")));
			mkdirSync(join(root, "dist/plugin/specrail/libexec"), { recursive: true });
			mkdirSync(join(root, "dist/plugin-smoke/config"), { recursive: true });
			writeFileSync(join(root, "dist/cli.js"), "#!/usr/bin/env node\n");
			writeFileSync(join(root, "dist/plugin/specrail/libexec/native-cli"), "binary");
			writeFileSync(join(root, "dist/plugin-smoke/config/settings.json"), "{}");
			const packed = spawnSync(process.execPath, ["pm", "pack", "--dry-run", "--ignore-scripts"], {
				cwd: root,
				encoding: "utf8",
			});
			expect(packed.status, packed.stderr).toBe(0);
			expect(packed.stdout).toContain("dist/cli.js");
			expect(packed.stdout).not.toContain("dist/plugin");
		} finally {
			rmSync(root, { recursive: true, force: true });
		}
	});
});
