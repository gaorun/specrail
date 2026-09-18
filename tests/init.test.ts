import { describe, expect, test } from "bun:test";
import { existsSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DistributeError, readConfig, writeConfig } from "../src/distribute/config.ts";
import { initProject, syncProject } from "../src/distribute/generate.ts";
import { RULE_BEGIN, RULE_TEXT } from "../src/distribute/rule.ts";
import { makeSkillsSource, runCli } from "./helpers.ts";

const VERSION = "9.9.9";

const SKILL_FILES = [
	".pi/prompts/specrail-brainstorming.md",
	".pi/prompts/specrail-shipping-a-pr.md",
	".pi/skills/specrail-brainstorming/SKILL.md",
	".pi/skills/specrail-shipping-a-pr/SKILL.md",
	".pi/skills/specrail-shipping-a-pr/checks.md",
	".qoder/commands/specrail/brainstorming.md",
	".qoder/commands/specrail/shipping-a-pr.md",
	".qoder/skills/specrail-brainstorming/SKILL.md",
	".qoder/skills/specrail-shipping-a-pr/SKILL.md",
	".qoder/skills/specrail-shipping-a-pr/checks.md",
	".specrail/.gitignore",
];

function fixture(): { root: string; skillsDir: string } {
	return {
		root: mkdtempSync(join(tmpdir(), "specrail-init-")),
		skillsDir: makeSkillsSource([
			{ name: "specrail-brainstorming" },
			{ name: "specrail-shipping-a-pr", files: { "checks.md": "# Checks\n" } },
		]),
	};
}

function currentConfig(root: string) {
	const config = readConfig(root);
	if (config === undefined) throw new Error("expected a .specrail/config.json");
	return config;
}

describe("init", () => {
	test("写入清单、命令与技能", () => {
		const { root, skillsDir } = fixture();
		const report = initProject({
			root,
			tools: ["qoder", "pi"],
			skillsDir,
			version: VERSION,
			rule: false,
		});
		expect(report.removed).toEqual([]);
		expect(report.ruleWritten).toBe(false);
		expect(currentConfig(root)).toEqual({
			version: VERSION,
			tools: ["qoder", "pi"],
			files: SKILL_FILES,
		});
		expect(report.files.every((rel) => existsSync(join(root, rel)))).toBe(true);
		expect(readdirSync(join(root, ".pi/prompts"))).toHaveLength(2);
		expect(readdirSync(join(root, ".qoder/commands/specrail"))).toHaveLength(2);
		expect(existsSync(join(root, ".agents"))).toBe(false);
		expect(readFileSync(join(root, ".specrail/.gitignore"), "utf8")).toBe("context/\n");
		const command = readFileSync(join(root, ".qoder/commands/specrail/brainstorming.md"), "utf8");
		expect(command).toContain('tags: ["specrail"]');
		expect(command).toContain("`.qoder/skills/specrail-brainstorming/SKILL.md`");
		const prompt = readFileSync(join(root, ".pi/prompts/specrail-brainstorming.md"), "utf8");
		expect(prompt).toContain("**Input**: $@");
	});

	test("重复执行幂等", () => {
		const { root, skillsDir } = fixture();
		initProject({ root, tools: ["qoder", "pi"], skillsDir, version: VERSION, rule: false });
		const before = currentConfig(root);
		const report = initProject({
			root,
			tools: ["qoder", "pi"],
			skillsDir,
			version: VERSION,
			rule: false,
		});
		expect(report.removed).toEqual([]);
		expect(currentConfig(root)).toEqual(before);
	});

	test("--rule 保留 AGENTS.md 其它内容且只有一个块", () => {
		const { root, skillsDir } = fixture();
		const agents = join(root, "AGENTS.md");
		writeFileSync(agents, "# Repo rules\n\nKeep me.\n", "utf8");
		const report = initProject({ root, tools: ["qoder"], skillsDir, version: VERSION, rule: true });
		expect(report.ruleWritten).toBe(true);
		const content = readFileSync(agents, "utf8");
		expect(content.startsWith("# Repo rules\n\nKeep me.\n")).toBe(true);
		expect(content).toContain(RULE_TEXT);
		expect(content.split(RULE_BEGIN)).toHaveLength(2);
		initProject({ root, tools: ["qoder"], skillsDir, version: VERSION, rule: true });
		expect(readFileSync(agents, "utf8")).toBe(content);
	});

	test("换成更少工具时清理清单内的旧产物", () => {
		const { root, skillsDir } = fixture();
		initProject({ root, tools: ["qoder", "pi"], skillsDir, version: VERSION, rule: false });
		const report = initProject({
			root,
			tools: ["qoder"],
			skillsDir,
			version: VERSION,
			rule: false,
		});
		expect(report.removed).toHaveLength(5);
		expect(existsSync(join(root, ".pi/prompts/specrail-brainstorming.md"))).toBe(false);
		expect(existsSync(join(root, ".pi/skills/specrail-brainstorming/SKILL.md"))).toBe(false);
		expect(existsSync(join(root, ".qoder/commands/specrail/brainstorming.md"))).toBe(true);
		expect(currentConfig(root).tools).toEqual(["qoder"]);
	});

	test("技能源缺失时报错且不写清单", () => {
		const { root } = fixture();
		expect(() =>
			initProject({
				root,
				tools: ["qoder"],
				skillsDir: join(root, "missing-skills"),
				version: VERSION,
				rule: false,
			}),
		).toThrow(DistributeError);
		expect(existsSync(join(root, ".specrail/config.json"))).toBe(false);
	});
});

describe("sync", () => {
	test("按清单刷新、清理不再期望的文件并更新版本", () => {
		const { root, skillsDir } = fixture();
		initProject({ root, tools: ["qoder", "pi"], skillsDir, version: VERSION, rule: false });
		writeConfig(root, { ...currentConfig(root), tools: ["qoder"] });
		const report = syncProject({ root, skillsDir, version: "9.9.10", rule: false });
		expect(report.removed).toEqual([
			".pi/prompts/specrail-brainstorming.md",
			".pi/prompts/specrail-shipping-a-pr.md",
			".pi/skills/specrail-brainstorming/SKILL.md",
			".pi/skills/specrail-shipping-a-pr/SKILL.md",
			".pi/skills/specrail-shipping-a-pr/checks.md",
		]);
		expect(existsSync(join(root, ".pi/skills/specrail-shipping-a-pr/checks.md"))).toBe(false);
		expect(existsSync(join(root, ".qoder/commands/specrail/brainstorming.md"))).toBe(true);
		const config = currentConfig(root);
		expect(config.tools).toEqual(["qoder"]);
		expect(config.version).toBe("9.9.10");
		expect(config.files).toHaveLength(6);
		expect(config.files.every((rel) => existsSync(join(root, rel)))).toBe(true);
	});

	test("绝不触碰未记录的文件", () => {
		const { root, skillsDir } = fixture();
		initProject({ root, tools: ["qoder"], skillsDir, version: VERSION, rule: false });
		const handmade = join(root, ".qoder/commands/specrail/handmade.md");
		writeFileSync(handmade, "keep me\n", "utf8");
		const agents = join(root, "AGENTS.md");
		writeFileSync(agents, "# user file\n", "utf8");
		const report = syncProject({ root, skillsDir, version: VERSION, rule: false });
		expect(report.removed).toEqual([]);
		expect(readFileSync(handmade, "utf8")).toBe("keep me\n");
		expect(readFileSync(agents, "utf8")).toBe("# user file\n");
	});

	test("记录过的文件被重写、被删除的记录文件会重建", () => {
		const { root, skillsDir } = fixture();
		initProject({ root, tools: ["qoder"], skillsDir, version: VERSION, rule: false });
		const command = join(root, ".qoder/commands/specrail/brainstorming.md");
		const skill = join(root, ".qoder/skills/specrail-brainstorming/SKILL.md");
		writeFileSync(command, "stale\n", "utf8");
		rmSync(skill);
		const report = syncProject({ root, skillsDir, version: VERSION, rule: false });
		expect(report.removed).toEqual([]);
		expect(readFileSync(command, "utf8")).toContain("Read and follow the skill");
		expect(readFileSync(skill, "utf8")).toContain("name: specrail-brainstorming");
	});

	test("--rule 建立块；已有块在无 --rule 时也被刷新", () => {
		const { root, skillsDir } = fixture();
		initProject({ root, tools: ["qoder"], skillsDir, version: VERSION, rule: false });
		const agents = join(root, "AGENTS.md");
		expect(existsSync(agents)).toBe(false);
		const created = syncProject({ root, skillsDir, version: VERSION, rule: true });
		expect(created.ruleWritten).toBe(true);
		const stale = readFileSync(agents, "utf8").replace(RULE_TEXT, "STALE RULE");
		writeFileSync(agents, stale, "utf8");
		const refreshed = syncProject({ root, skillsDir, version: VERSION, rule: false });
		expect(refreshed.ruleWritten).toBe(true);
		expect(readFileSync(agents, "utf8")).toBe(stale.replace("STALE RULE", RULE_TEXT));
	});

	test("无清单时报错", () => {
		const { root, skillsDir } = fixture();
		expect(() => syncProject({ root, skillsDir, version: VERSION, rule: false })).toThrow(
			DistributeError,
		);
		expect(() => syncProject({ root, skillsDir, version: VERSION, rule: false })).toThrow(
			'Run "specrail init" first',
		);
	});

	test("损坏清单报错", () => {
		const { root, skillsDir } = fixture();
		writeConfig(root, { version: VERSION, tools: ["qoder"], files: [] });
		writeFileSync(join(root, ".specrail/config.json"), "{ broken", "utf8");
		expect(() => syncProject({ root, skillsDir, version: VERSION, rule: false })).toThrow(
			"Unable to read .specrail/config.json",
		);
	});
});

describe("cli", () => {
	test("--help 列出 init 与 sync", () => {
		const result = runCli(["--help"]);
		expect(result.status).toBe(0);
		for (const name of ["init", "sync"]) expect(result.stdout).toContain(name);
	});

	test("非法 --tools 返回 2 且不写文件", () => {
		const root = mkdtempSync(join(tmpdir(), "specrail-init-"));
		const result = runCli(["init", "--tools", "qoder,bogus", "--root", root]);
		expect(result.status).toBe(2);
		expect(result.stderr).toContain(
			"--tools must be a comma-separated list of: qoder, claude, codex, pi",
		);
		expect(existsSync(join(root, ".specrail"))).toBe(false);
	});

	test("缺少 --tools 返回 2", () => {
		const root = mkdtempSync(join(tmpdir(), "specrail-init-"));
		const result = runCli(["init", "--root", root]);
		expect(result.status).toBe(2);
		expect(result.stderr).toContain("--tools is required");
	});

	test("init 拒绝位置参数与未知参数", () => {
		const root = mkdtempSync(join(tmpdir(), "specrail-init-"));
		expect(runCli(["init", "extra", "--tools", "pi", "--root", root]).status).toBe(2);
		expect(runCli(["init", "--tools", "pi", "--root", root, "--bogus"]).status).toBe(2);
	});

	test("sync 无清单返回 2", () => {
		const root = mkdtempSync(join(tmpdir(), "specrail-init-"));
		const result = runCli(["sync", "--root", root]);
		expect(result.status).toBe(2);
		expect(result.stderr).toContain("No .specrail/config.json under");
		expect(result.stderr).toContain('Run "specrail init" first.');
	});

	test("sync 遇上损坏清单返回 2", () => {
		const root = mkdtempSync(join(tmpdir(), "specrail-init-"));
		writeConfig(root, { version: VERSION, tools: ["qoder"], files: [] });
		writeFileSync(join(root, ".specrail/config.json"), "{ broken", "utf8");
		const result = runCli(["sync", "--root", root]);
		expect(result.status).toBe(2);
		expect(result.stderr).toContain("Unable to read .specrail/config.json");
	});

	test("sync 拒绝位置参数", () => {
		const root = mkdtempSync(join(tmpdir(), "specrail-init-"));
		expect(runCli(["sync", "extra", "--root", root]).status).toBe(2);
	});
});
