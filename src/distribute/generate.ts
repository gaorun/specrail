import { existsSync, mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { parse as parseYaml } from "yaml";
import {
	type GeneratedFile,
	renderCommandFiles,
	renderSkillFiles,
	SKILL_PREFIX,
	type SkillFile,
	type SkillSource,
	type Tool,
} from "./adapters.ts";
import { CONFIG_PATH, DistributeError, errorDetail, readConfig, writeConfig } from "./config.ts";
import { hasRuleBlock, RULE_TEXT, upsertRuleBlock } from "./rule.ts";

const SKILLS_SOURCES = ["../skills/", "../../skills/"];
const FRONTMATTER = /^---\r?\n([\s\S]*?)\r?\n---/;
const AGENTS_FILE = "AGENTS.md";
const CONTEXT_IGNORE_PATH = ".specrail/.gitignore";
const CONTEXT_IGNORE_CONTENT = "context/\n";

export interface InitOptions {
	root: string;
	tools: readonly Tool[];
	skillsDir: string;
	version: string;
	rule: boolean;
}

export interface SyncOptions {
	root: string;
	skillsDir: string;
	version: string;
	rule: boolean;
}

export interface ApplyReport {
	tools: readonly Tool[];
	files: readonly string[];
	removed: readonly string[];
	ruleWritten: boolean;
}

export function packagedSkillsDir(): string {
	for (const source of SKILLS_SOURCES) {
		const dir = fileURLToPath(new URL(source, import.meta.url));
		if (existsSync(dir)) return dir;
	}
	throw new DistributeError("Unable to locate the packaged skills directory");
}

export function readSkills(skillsDir: string): SkillSource[] {
	if (!existsSync(skillsDir)) {
		throw new DistributeError(`Skills source directory not found: ${skillsDir}`);
	}
	return readdirSync(skillsDir, { withFileTypes: true })
		.filter((entry) => entry.isDirectory() && existsSync(join(skillsDir, entry.name, "SKILL.md")))
		.map((entry) => readSkill(skillsDir, entry.name))
		.sort((a, b) => compareText(a.name, b.name));
}

export function expectedFiles(skillsDir: string, tools: readonly Tool[]): GeneratedFile[] {
	const skills = readSkills(skillsDir);
	return [
		{ path: CONTEXT_IGNORE_PATH, content: CONTEXT_IGNORE_CONTENT },
		...tools.flatMap((tool) => [
			...renderSkillFiles(tool, skills),
			...renderCommandFiles(tool, skills),
		]),
	].sort((a, b) => compareText(a.path, b.path));
}

export function initProject(options: InitOptions): ApplyReport {
	const previous = readConfig(options.root)?.files ?? [];
	return reconcile({ ...options, previous });
}

export function syncProject(options: SyncOptions): ApplyReport {
	const config = readConfig(options.root);
	if (config === undefined) {
		throw new DistributeError(
			`No ${CONFIG_PATH} under ${options.root}. Run "specrail init" first.`,
		);
	}
	return reconcile({ ...options, tools: config.tools, previous: config.files });
}

function reconcile(input: {
	root: string;
	tools: readonly Tool[];
	skillsDir: string;
	version: string;
	previous: readonly string[];
	rule: boolean;
}): ApplyReport {
	const files = expectedFiles(input.skillsDir, input.tools);
	const paths = files.map((file) => file.path);
	writeFiles(input.root, files);
	const expected = new Set(paths);
	const removed = removeFiles(
		input.root,
		input.previous.filter((rel) => !expected.has(rel)),
	);
	const ruleWritten = applyRule(input.root, input.rule);
	writeConfig(input.root, {
		version: input.version,
		tools: [...input.tools],
		files: paths,
	});
	return { tools: input.tools, files: paths, removed, ruleWritten };
}

function applyRule(root: string, rule: boolean): boolean {
	const agentsPath = join(root, AGENTS_FILE);
	if (!rule && !hasRuleBlock(agentsPath)) return false;
	upsertRuleBlock(agentsPath, RULE_TEXT);
	return true;
}

function writeFiles(root: string, files: readonly GeneratedFile[]): void {
	for (const file of files) {
		const abs = join(root, file.path);
		try {
			mkdirSync(dirname(abs), { recursive: true });
			writeFileSync(abs, file.content, "utf8");
		} catch (error) {
			throw new DistributeError(`Unable to write ${file.path}: ${errorDetail(error)}`);
		}
	}
}

function removeFiles(root: string, paths: readonly string[]): string[] {
	const removed: string[] = [];
	for (const rel of paths) {
		const abs = join(root, rel);
		if (!existsSync(abs)) continue;
		try {
			rmSync(abs);
		} catch (error) {
			throw new DistributeError(`Unable to remove ${rel}: ${errorDetail(error)}`);
		}
		removed.push(rel);
	}
	return removed;
}

function readSkill(skillsDir: string, dir: string): SkillSource {
	const files = readDirFiles(join(skillsDir, dir));
	const skillFile = files.find((file) => file.path === "SKILL.md");
	if (skillFile === undefined) throw new DistributeError(`${dir}/SKILL.md is missing`);
	const { name, description } = skillFrontmatter(skillFile.content, dir);
	if (name !== dir) {
		throw new DistributeError(
			`${dir}/SKILL.md declares name "${name}"; the directory name must match it`,
		);
	}
	if (!name.startsWith(SKILL_PREFIX)) {
		throw new DistributeError(`${dir}: skill names must start with "${SKILL_PREFIX}"`);
	}
	return { id: name.slice(SKILL_PREFIX.length), name, description, files };
}

function skillFrontmatter(content: string, dir: string): { name: string; description: string } {
	const match = FRONTMATTER.exec(content);
	if (match === null) throw new DistributeError(`${dir}/SKILL.md has no YAML frontmatter`);
	const parsed: unknown = parseYaml(match[1] ?? "");
	if (typeof parsed !== "object" || parsed === null) {
		throw new DistributeError(`${dir}/SKILL.md frontmatter must be a YAML mapping`);
	}
	const name = "name" in parsed ? parsed.name : undefined;
	const description = "description" in parsed ? parsed.description : undefined;
	if (
		typeof name !== "string" ||
		name === "" ||
		typeof description !== "string" ||
		description === ""
	) {
		throw new DistributeError(`${dir}/SKILL.md must declare a non-empty name and description`);
	}
	return { name, description };
}

function readDirFiles(dir: string, prefix = ""): SkillFile[] {
	const entries = readdirSync(dir, { withFileTypes: true }).sort((a, b) =>
		compareText(a.name, b.name),
	);
	return entries.flatMap((entry) => {
		const path = prefix === "" ? entry.name : `${prefix}/${entry.name}`;
		if (entry.isDirectory()) return readDirFiles(join(dir, entry.name), path);
		if (entry.isFile()) return [{ path, content: readFileSync(join(dir, entry.name), "utf8") }];
		return [];
	});
}

function compareText(a: string, b: string): number {
	if (a === b) return 0;
	return a < b ? -1 : 1;
}
