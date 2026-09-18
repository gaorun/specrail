import { isValid, SpecIndex, validateGraph } from "../../core/index.ts";
import { parseCommandArgs, rootFrom } from "../args.ts";
import { print, printJson } from "../out.ts";

export async function run(argv: string[]): Promise<number> {
	const { values } = parseCommandArgs(argv, {});
	const report = validateGraph(new SpecIndex(rootFrom(values)).graph());
	if (values.json === true) {
		printJson(report);
		return isValid(report) ? 0 : 1;
	}
	if (isValid(report)) {
		print("Spec-graph is valid: no issues found.");
		return 0;
	}

	const sections: string[] = [];
	if (report.duplicateIds.length) {
		sections.push(
			`Duplicate ids (${report.duplicateIds.length}):\n${report.duplicateIds
				.map((duplicate) => `  ${duplicate.id}: ${duplicate.paths.join(", ")}`)
				.join("\n")}`,
		);
	}
	if (report.danglingLinks.length) {
		sections.push(
			`Dangling links (${report.danglingLinks.length}):\n${report.danglingLinks
				.map(
					(link) => `  ${link.from} (${link.fromPath}) --${link.kind}--> ${link.target} [missing]`,
				)
				.join("\n")}`,
		);
	}
	if (report.parentCycles.length) {
		sections.push(
			`Parent cycles (${report.parentCycles.length}):\n${report.parentCycles
				.map((cycle) => `  ${cycle.ids.join(" -> ")} -> ${cycle.ids[0]}`)
				.join("\n")}`,
		);
	}
	print(sections.join("\n\n"));
	return 1;
}
