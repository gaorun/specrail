export interface GeneratedFile {
	path: string;
	content: string;
}

export interface SkillFile {
	path: string;
	content: string;
}

export interface SkillMeta {
	id: string;
	name: string;
	description: string;
}

export interface SkillSource extends SkillMeta {
	files: SkillFile[];
}

export const SKILL_PREFIX = "specrail-";

export const TOOLS = ["qoder", "claude", "codex", "pi"] as const;

export type Tool = (typeof TOOLS)[number];

const COMMAND_SCOPE = "specrail";

interface CommandSurface {
	path(skill: SkillMeta): string;
	frontmatter(skill: SkillMeta): string;
	input?: string;
}

interface ToolSurface {
	skillsRoot: string;
	command?: CommandSurface;
}

function scalar(value: string): string {
	return JSON.stringify(value);
}

function tagsLine(tags: readonly string[]): string {
	return `[${tags.map(scalar).join(", ")}]`;
}

const TOOL_SURFACES: Record<Tool, ToolSurface> = {
	pi: {
		skillsRoot: ".pi/skills",
		command: {
			path: (skill) => `.pi/prompts/${skill.name}.md`,
			frontmatter: (skill) => `description: ${scalar(skill.description)}`,
			input: "$@",
		},
	},
	qoder: {
		skillsRoot: ".qoder/skills",
		command: {
			path: (skill) => `.qoder/commands/${COMMAND_SCOPE}/${skill.id}.md`,
			frontmatter: (skill) =>
				[
					`name: ${scalar(skill.name)}`,
					`description: ${scalar(skill.description)}`,
					`category: ${scalar(COMMAND_SCOPE)}`,
					`tags: ${tagsLine([COMMAND_SCOPE])}`,
				].join("\n"),
		},
	},
	claude: {
		skillsRoot: ".claude/skills",
		command: {
			path: (skill) => `.claude/commands/${COMMAND_SCOPE}/${skill.id}.md`,
			frontmatter: (skill) =>
				[
					`name: ${scalar(skill.name)}`,
					`description: ${scalar(skill.description)}`,
					`allowed-tools: Bash(${COMMAND_SCOPE}:*)`,
					`category: ${scalar(COMMAND_SCOPE)}`,
					`tags: ${tagsLine([COMMAND_SCOPE])}`,
				].join("\n"),
			input: "$ARGUMENTS",
		},
	},
	codex: {
		skillsRoot: ".agents/skills",
	},
};

export function renderSkillFiles(tool: Tool, skills: readonly SkillSource[]): GeneratedFile[] {
	const { skillsRoot } = TOOL_SURFACES[tool];
	return skills.flatMap((skill) =>
		skill.files.map((file) => ({
			path: `${skillsRoot}/${skill.name}/${file.path}`,
			content: file.content,
		})),
	);
}

export function renderCommandFiles(tool: Tool, skills: readonly SkillMeta[]): GeneratedFile[] {
	const surface = TOOL_SURFACES[tool];
	const command = surface.command;
	if (command === undefined) return [];
	return skills.map((skill) => ({
		path: command.path(skill),
		content: commandFile(skill, `${surface.skillsRoot}/${skill.name}/SKILL.md`, command),
	}));
}

function commandFile(skill: SkillMeta, skillPath: string, command: CommandSurface): string {
	const input = command.input === undefined ? "" : `\n\n**Input**: ${command.input}`;
	return `---\n${command.frontmatter(skill)}\n---\n\nRead and follow the skill at \`${skillPath}\` for the current task.${input}\n`;
}
