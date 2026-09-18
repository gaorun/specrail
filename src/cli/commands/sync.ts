import { packagedSkillsDir, syncProject } from "../../distribute/generate.ts";
import { parseCommandArgs, rootFrom, UsageError } from "../args.ts";
import { printJson } from "../out.ts";
import { printApplyReport } from "../report.ts";
import { packageVersion } from "../version.ts";

export async function run(argv: string[]): Promise<number> {
	const { values, positionals } = parseCommandArgs(argv, { rule: { type: "boolean" } });
	if (positionals.length > 0) throw new UsageError("sync takes no positional arguments.");
	const version = packageVersion();
	const report = syncProject({
		root: rootFrom(values),
		skillsDir: packagedSkillsDir(),
		version,
		rule: values.rule === true,
	});
	if (values.json === true) printJson(report);
	else printApplyReport("Synced", version, report);
	return 0;
}
