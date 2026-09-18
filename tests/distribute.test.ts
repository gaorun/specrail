import { describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
	renderCommandFiles,
	renderSkillFiles,
	type SkillMeta,
	type SkillSource,
	TOOLS,
} from "../src/distribute/adapters.ts";
import { DistributeError, readConfig, writeConfig } from "../src/distribute/config.ts";
import { expectedFiles, readSkills } from "../src/distribute/generate.ts";
import { RULE_BEGIN, RULE_END, RULE_TEXT, upsertRuleBlock } from "../src/distribute/rule.ts";
import { makeSkillsSource } from "./helpers.ts";

function tempDir(): string {
	return mkdtempSync(join(tmpdir(), "specrail-distribute-"));
}

const BRAINSTORMING: SkillMeta = {
	id: "brainstorming",
	name: "specrail-brainstorming",
	description: 'Use when a design choice is open: "scope", behavior, or architecture.',
};

const SHIPPING: SkillSource = {
	id: "shipping-a-pr",
	name: "specrail-shipping-a-pr",
	description: "Use for PR lifecycle work.",
	files: [
		{ path: "SKILL.md", content: "---\nname: specrail-shipping-a-pr\n---\n\n# Shipping\n" },
		{ path: "checks.md", content: "# Checks\n" },
	],
};

describe("config 清单", () => {
	test("读写往返", () => {
		const root = tempDir();
		writeConfig(root, {
			version: "9.9.9",
			tools: ["qoder", "pi"],
			files: [".qoder/commands/specrail/brainstorming.md"],
		});
		expect(readConfig(root)).toEqual({
			version: "9.9.9",
			tools: ["qoder", "pi"],
			files: [".qoder/commands/specrail/brainstorming.md"],
		});
		expect(readFileSync(join(root, ".specrail/config.json"), "utf8").endsWith("\n")).toBe(true);
	});

	test("无清单返回 undefined", () => {
		expect(readConfig(tempDir())).toBeUndefined();
	});

	test("损坏 JSON 明确报错", () => {
		const root = tempDir();
		mkdirSync(join(root, ".specrail"), { recursive: true });
		writeFileSync(join(root, ".specrail/config.json"), "{ not json", "utf8");
		expect(() => readConfig(root)).toThrow(DistributeError);
		expect(() => readConfig(root)).toThrow(".specrail/config.json");
	});

	test("未知工具与越界路径被拒", () => {
		const root = tempDir();
		const configPath = join(root, ".specrail/config.json");
		mkdirSync(join(root, ".specrail"), { recursive: true });
		writeFileSync(
			configPath,
			JSON.stringify({ version: "1.0.0", tools: ["bogus"], files: [] }),
			"utf8",
		);
		expect(() => readConfig(root)).toThrow("tools must come from: qoder, claude, codex, pi");
		writeFileSync(
			configPath,
			JSON.stringify({ version: "1.0.0", tools: ["pi"], files: ["../escape.md"] }),
			"utf8",
		);
		expect(() => readConfig(root)).toThrow("files must be root-relative paths");
		writeFileSync(
			configPath,
			JSON.stringify({ version: "1.0.0", tools: ["pi"], files: ["/abs.md"] }),
			"utf8",
		);
		expect(() => readConfig(root)).toThrow("files must be root-relative paths");
	});
});

describe("AGENTS.md 规则块", () => {
	test("规则文本逐字固定", () => {
		expect(RULE_TEXT).toBe(
			[
				"At the start of a new piece of work, read the specrail-choosing-a-workflow skill for project onboarding or any PR lifecycle work.",
				"For other new changes, read it only when product scope, user-visible behavior, or architecture remains to decide.",
				"Continue work already routed to a workflow without routing it again; otherwise proceed directly without loading or announcing one.",
			].join("\n"),
		);
	});

	test("无文件时创建并包裹标记", () => {
		const path = join(tempDir(), "AGENTS.md");
		upsertRuleBlock(path, RULE_TEXT);
		expect(readFileSync(path, "utf8")).toBe(`${RULE_BEGIN}\n${RULE_TEXT}\n${RULE_END}\n`);
	});

	test("已有内容追加在末尾且原文完整保留", () => {
		const path = join(tempDir(), "AGENTS.md");
		const original = "# House rules\n\n- keep me\n";
		writeFileSync(path, original, "utf8");
		upsertRuleBlock(path, RULE_TEXT);
		const content = readFileSync(path, "utf8");
		expect(content.startsWith(original)).toBe(true);
		expect(content).toContain(`${RULE_BEGIN}\n${RULE_TEXT}\n${RULE_END}`);
	});

	test("二次调用幂等且旧块内文本被替换", () => {
		const path = join(tempDir(), "AGENTS.md");
		writeFileSync(path, "# House rules\n", "utf8");
		upsertRuleBlock(path, "OLD RULE");
		expect(readFileSync(path, "utf8")).toContain("OLD RULE");
		upsertRuleBlock(path, RULE_TEXT);
		const replaced = readFileSync(path, "utf8");
		expect(replaced).not.toContain("OLD RULE");
		expect(replaced.split(RULE_BEGIN)).toHaveLength(2);
		expect(replaced.startsWith("# House rules\n")).toBe(true);
		upsertRuleBlock(path, RULE_TEXT);
		expect(readFileSync(path, "utf8")).toBe(replaced);
	});
});

describe("适配器渲染", () => {
	test("工具表", () => {
		expect([...TOOLS]).toEqual(["qoder", "claude", "codex", "pi"]);
	});

	test("pi 命令：prompts 文件、description frontmatter、$@ 注入", () => {
		const [file] = renderCommandFiles("pi", [BRAINSTORMING]);
		expect(file?.path).toBe(".pi/prompts/specrail-brainstorming.md");
		expect(
			file?.content.startsWith('---\ndescription: "Use when a design choice is open: \\"scope\\"'),
		).toBe(true);
		expect(file?.content).toContain("`.pi/skills/specrail-brainstorming/SKILL.md`");
		expect(file?.content).toContain("**Input**: $@");
	});

	test("qoder 命令：specrail 命名空间的 name/description/category/tags", () => {
		const [file] = renderCommandFiles("qoder", [BRAINSTORMING]);
		expect(file?.path).toBe(".qoder/commands/specrail/brainstorming.md");
		expect(file?.content).toContain('name: "specrail-brainstorming"');
		expect(file?.content).toContain('category: "specrail"');
		expect(file?.content).toContain('tags: ["specrail"]');
		expect(file?.content).not.toContain("$@");
	});

	test("claude 命令：specrail 命名空间与 allowed-tools", () => {
		const [file] = renderCommandFiles("claude", [BRAINSTORMING]);
		expect(file?.path).toBe(".claude/commands/specrail/brainstorming.md");
		expect(file?.content).toContain('name: "specrail-brainstorming"');
		expect(file?.content).toContain("allowed-tools: Bash(specrail:*)");
		expect(file?.content).toContain("**Input**: $ARGUMENTS");
	});

	test("codex 只有技能面", () => {
		expect(renderCommandFiles("codex", [BRAINSTORMING])).toEqual([]);
		expect(renderSkillFiles("codex", [SHIPPING]).map((file) => file.path)).toEqual([
			".agents/skills/specrail-shipping-a-pr/SKILL.md",
			".agents/skills/specrail-shipping-a-pr/checks.md",
		]);
	});

	test("技能文件按工具根落位并携带兄弟文档", () => {
		const roots = {
			qoder: ".qoder/skills",
			claude: ".claude/skills",
			codex: ".agents/skills",
			pi: ".pi/skills",
		};
		for (const tool of TOOLS) {
			expect(renderSkillFiles(tool, [SHIPPING]).map((file) => file.path)).toEqual([
				`${roots[tool]}/specrail-shipping-a-pr/SKILL.md`,
				`${roots[tool]}/specrail-shipping-a-pr/checks.md`,
			]);
		}
	});
});

describe("技能源读取", () => {
	test("按名排序并解析 frontmatter", () => {
		const dir = makeSkillsSource([
			{ name: "specrail-shipping-a-pr", files: { "checks.md": "# Checks\n" } },
			{ name: "specrail-brainstorming" },
		]);
		const skills = readSkills(dir);
		expect(skills.map((skill) => skill.name)).toEqual([
			"specrail-brainstorming",
			"specrail-shipping-a-pr",
		]);
		expect(skills[0]?.id).toBe("brainstorming");
		expect(skills[0]?.description).toBe("Description of specrail-brainstorming.");
		expect(skills[1]?.files.map((file) => file.path)).toEqual(["SKILL.md", "checks.md"]);
	});

	test("忽略非技能文件与无 SKILL.md 目录", () => {
		const dir = tempDir();
		writeFileSync(join(dir, "SPEC.md"), "---\nid: skills\n---\n", "utf8");
		mkdirSync(join(dir, "not-a-skill"), { recursive: true });
		expect(readSkills(dir)).toEqual([]);
	});

	test("缺少 description 报错", () => {
		const dir = makeSkillsSource([
			{ name: "specrail-broken", skillMd: "---\nname: specrail-broken\n---\n\n# Broken\n" },
		]);
		expect(() => readSkills(dir)).toThrow("must declare a non-empty name and description");
	});

	test("目录名与 name 不一致报错", () => {
		const dir = makeSkillsSource([
			{ name: "specrail-renamed", skillMd: "---\nname: specrail-other\ndescription: x\n---\n" },
		]);
		expect(() => readSkills(dir)).toThrow('declares name "specrail-other"');
	});

	test("缺少 specrail- 前缀报错", () => {
		const dir = makeSkillsSource([
			{ name: "unprefixed", skillMd: "---\nname: unprefixed\ndescription: x\n---\n" },
		]);
		expect(() => readSkills(dir)).toThrow('must start with "specrail-"');
	});

	test("期望文件集汇总技能与命令", () => {
		const dir = makeSkillsSource([{ name: "specrail-brainstorming" }]);
		expect(expectedFiles(dir, ["qoder"]).map((file) => file.path)).toEqual([
			".qoder/commands/specrail/brainstorming.md",
			".qoder/skills/specrail-brainstorming/SKILL.md",
			".specrail/.gitignore",
		]);
		expect(expectedFiles(dir, ["codex"]).map((file) => file.path)).toEqual([
			".agents/skills/specrail-brainstorming/SKILL.md",
			".specrail/.gitignore",
		]);
		expect(expectedFiles(dir, ["pi", "codex"]).map((file) => file.path)).toEqual([
			".agents/skills/specrail-brainstorming/SKILL.md",
			".pi/prompts/specrail-brainstorming.md",
			".pi/skills/specrail-brainstorming/SKILL.md",
			".specrail/.gitignore",
		]);
	});
});
