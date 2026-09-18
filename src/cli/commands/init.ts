import { TOOLS, type Tool } from "../../distribute/adapters.ts";
import { initProject, packagedSkillsDir } from "../../distribute/generate.ts";
import { parseCommandArgs, rootFrom, UsageError } from "../args.ts";
import { printJson } from "../out.ts";
import { printApplyReport } from "../report.ts";
import { packageVersion } from "../version.ts";

export async function run(argv: string[]): Promise<number> {
	const { values, positionals } = parseCommandArgs(argv, {
		tools: { type: "string" },
		rule: { type: "boolean" },
	});
	if (positionals.length > 0) throw new UsageError("init takes no positional arguments.");
	const tools = parseTools(values.tools);
	const version = packageVersion();
	const report = initProject({
		root: rootFrom(values),
		tools,
		skillsDir: packagedSkillsDir(),
		version,
		rule: values.rule === true,
	});
	if (values.json === true) printJson(report);
	else printApplyReport("Initialized", version, report);
	return 0;
}

function parseTools(value: string | undefined): Tool[] {
	const names = (value ?? "")
		.split(",")
		.map((name) => name.trim())
		.filter((name) => name !== "");
	if (names.length === 0) throw new UsageError(`--tools is required: ${TOOLS.join(", ")}`);
	const tools: Tool[] = [];
	for (const name of names) {
		const tool = TOOLS.find((candidate) => candidate === name);
		if (tool === undefined) {
			throw new UsageError(`--tools must be a comma-separated list of: ${TOOLS.join(", ")}`);
		}
		if (!tools.includes(tool)) tools.push(tool);
	}
	return tools;
}
