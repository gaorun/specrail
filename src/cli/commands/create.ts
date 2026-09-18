import { existsSync, mkdirSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import {
	FIELDS,
	type Frontmatter,
	isSpec,
	parseFile,
	resolveSpecPath,
	SPEC_STATUSES,
	SPEC_TYPES,
	SpecIndex,
	type SpecType,
	serializeFrontmatter,
} from "../../core/index.ts";
import { parseCommandArgs, rootFrom, UsageError } from "../args.ts";
import { print, printJson } from "../out.ts";

const SCAFFOLD_HEADINGS: Record<SpecType, readonly string[]> = {
	"module-design": ["Responsibility", "Boundary"],
	"submodule-design": ["Responsibility", "Boundary"],
	"architecture-design": ["Drivers", "Decisions", "Invariants", "Out of scope"],
	"goal-and-requirements": ["Goal", "Scope"],
	"task-spec": ["Purpose", "Open items"],
};

function scaffoldBody(type: SpecType): string {
	return SCAFFOLD_HEADINGS[type].map((heading) => `## ${heading}\n`).join("\n");
}

export async function run(argv: string[]): Promise<number> {
	const { values, positionals } = parseCommandArgs(argv, {
		id: { type: "string" },
		type: { type: "string" },
		title: { type: "string" },
		status: { type: "string" },
		parent: { type: "string" },
		"depends-on": { type: "string", multiple: true },
		references: { type: "string", multiple: true },
		implements: { type: "string", multiple: true },
		covers: { type: "string", multiple: true },
		tags: { type: "string", multiple: true },
	});
	const path = positionals[0];
	if (path === undefined) throw new UsageError("create requires a path argument.");
	const id = values.id;
	if (id === undefined) throw new UsageError("--id is required.");
	const type = SPEC_TYPES.find((candidate) => candidate === values.type);
	if (type === undefined) throw new UsageError(`--type must be one of: ${SPEC_TYPES.join(", ")}`);
	const title = values.title;
	if (title === undefined) throw new UsageError("--title is required.");
	const status = SPEC_STATUSES.find((candidate) => candidate === values.status);
	if (values.status !== undefined && status === undefined) {
		throw new UsageError(`--status must be one of: ${SPEC_STATUSES.join(", ")}`);
	}

	const root = rootFrom(values);
	const resolved = resolveSpecPath(root, path);
	if ("error" in resolved) {
		process.stderr.write(`${resolved.error}\n`);
		return 2;
	}
	const { rel, abs } = resolved;
	const index = new SpecIndex(root);
	if (existsSync(abs)) {
		process.stderr.write(`File already exists: ${rel}\n`);
		return 2;
	}
	if (index.graph().nodes.has(id)) {
		process.stderr.write(`Spec id "${id}" is already in use.\n`);
		return 2;
	}

	const frontmatter: Frontmatter = { [FIELDS.id]: id, [FIELDS.type]: type };
	if (status !== undefined) frontmatter[FIELDS.status] = status;
	frontmatter[FIELDS.title] = title;
	if (values.parent !== undefined) frontmatter[FIELDS.parent] = values.parent;
	if (values["depends-on"]?.length) frontmatter[FIELDS.dependsOn] = values["depends-on"];
	if (values.references?.length) frontmatter[FIELDS.references] = values.references;
	if (values.implements?.length) frontmatter[FIELDS.implements] = values.implements;
	if (values.covers?.length) frontmatter[FIELDS.covers] = values.covers;
	if (values.tags?.length) frontmatter[FIELDS.tags] = values.tags;

	const content = `${serializeFrontmatter(frontmatter)}\n${scaffoldBody(type)}`;
	if (!isSpec(parseFile(content).frontmatter)) {
		process.stderr.write(
			`Refusing to write ${rel}: the frontmatter would not be a spec (id and type must be non-empty).\n`,
		);
		return 2;
	}
	try {
		mkdirSync(dirname(abs), { recursive: true });
		writeFileSync(abs, content, { encoding: "utf8", flag: "wx" });
	} catch (err) {
		process.stderr.write(
			`Failed to write ${rel}: ${err instanceof Error ? err.message : String(err)}\n`,
		);
		return 2;
	}
	const details = { path: rel, id };
	if (values.json === true) printJson(details);
	else print(`Created ${rel} (id: ${id}).`);
	return 0;
}
