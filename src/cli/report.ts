import type { ApplyReport } from "../distribute/generate.ts";
import { print } from "./out.ts";

export function printApplyReport(label: string, version: string, report: ApplyReport): void {
	const counts = [`${report.files.length} files`];
	if (report.removed.length > 0) counts.push(`removed ${report.removed.length}`);
	print(`${label} specrail ${version} for ${report.tools.join(", ")} (${counts.join(", ")}).`);
	if (report.ruleWritten) print("Rule block written to AGENTS.md.");
}
