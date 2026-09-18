import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const CLI_ENTRY = join(import.meta.dir, "..", "src", "cli.ts");

export interface CliResult {
	status: number | null;
	stdout: string;
	stderr: string;
}

export function runCli(args: string[]): CliResult {
	const result = spawnSync("bun", [CLI_ENTRY, ...args], { encoding: "utf8" });
	return { status: result.status, stdout: result.stdout, stderr: result.stderr };
}

export interface PtyResult {
	status: number;
	output: string;
}

export async function runCliInPty(args: string[], answer: string): Promise<PtyResult> {
	let output = "";
	let answered = false;
	const decoder = new TextDecoder();
	const proc = Bun.spawn(["bun", CLI_ENTRY, ...args], {
		terminal: {
			data: (terminal, chunk) => {
				output += decoder.decode(chunk);
				if (answered || !output.includes("[y/N]")) return;
				answered = true;
				setTimeout(() => terminal.write(answer), 100);
			},
		},
	});
	const timeout = setTimeout(() => proc.kill(), 10_000);
	const status = await proc.exited;
	clearTimeout(timeout);
	proc.terminal?.close();
	return { status, output };
}

export function writeFixtureFile(root: string, rel: string, body: string): void {
	mkdirSync(join(root, rel, ".."), { recursive: true });
	writeFileSync(join(root, rel), body, "utf8");
}

export function makeFixtureRepo(): string {
	const root = mkdtempSync(join(tmpdir(), "specrail-"));
	const write = (rel: string, body: string) => writeFixtureFile(root, rel, body);
	write("goal.md", "---\nid: goal\ntype: goal-and-requirements\ntitle: 目标\n---\n\n## Goal\n");
	write(
		"mods/a/SPEC.md",
		"---\nid: mod-a\ntype: module-design\ntitle: A 模块\nparent: goal\ndepends-on:\n  - mod-b\ntags:\n  - core\n---\n\n## Responsibility\nwidget rendering\n",
	);
	write(
		"mods/b/SPEC.md",
		"---\nid: mod-b\ntype: module-design\nparent: goal\n---\n\n## Responsibility\nstorage\n",
	);
	write("notes.txt", "not a spec");
	return root;
}

export interface SkillFixture {
	name: string;
	skillMd?: string;
	files?: Record<string, string>;
}

export function makeSkillsSource(skills: readonly SkillFixture[]): string {
	const root = mkdtempSync(join(tmpdir(), "specrail-skills-"));
	for (const skill of skills) {
		const dir = join(root, skill.name);
		mkdirSync(dir, { recursive: true });
		writeFileSync(
			join(dir, "SKILL.md"),
			skill.skillMd ??
				`---\nname: ${skill.name}\ndescription: "Description of ${skill.name}."\n---\n\n# ${skill.name}\n`,
			"utf8",
		);
		for (const [rel, content] of Object.entries(skill.files ?? {})) {
			mkdirSync(join(dir, rel, ".."), { recursive: true });
			writeFileSync(join(dir, rel), content, "utf8");
		}
	}
	return root;
}
