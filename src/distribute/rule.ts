import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import { DistributeError, errorDetail } from "./config.ts";

export const RULE_BEGIN = "<!-- specrail:rule:begin -->";
export const RULE_END = "<!-- specrail:rule:end -->";

export const RULE_TEXT = [
	"At the start of a new piece of work, read the specrail-choosing-a-workflow skill for project onboarding or any PR lifecycle work.",
	"For other new changes, read it only when product scope, user-visible behavior, or architecture remains to decide.",
	"Continue work already routed to a workflow without routing it again; otherwise proceed directly without loading or announcing one.",
].join("\n");

export function hasRuleBlock(agentsPath: string): boolean {
	const content = readAgents(agentsPath) ?? "";
	return content.includes(RULE_BEGIN) && content.includes(RULE_END);
}

export function upsertRuleBlock(agentsPath: string, ruleText: string): void {
	const block = `${RULE_BEGIN}\n${ruleText}\n${RULE_END}`;
	const existing = readAgents(agentsPath);
	if (existing === undefined) {
		writeAgents(agentsPath, `${block}\n`);
		return;
	}
	const start = existing.indexOf(RULE_BEGIN);
	const end = existing.indexOf(RULE_END);
	const next =
		start === -1 || end === -1 || end < start
			? `${existing}${existing.endsWith("\n") ? "" : "\n"}\n${block}\n`
			: `${existing.slice(0, start)}${block}${existing.slice(end + RULE_END.length)}`;
	writeAgents(agentsPath, next);
}

function readAgents(agentsPath: string): string | undefined {
	if (!existsSync(agentsPath)) return undefined;
	try {
		return readFileSync(agentsPath, "utf8");
	} catch (error) {
		throw new DistributeError(`Unable to read ${agentsPath}: ${errorDetail(error)}`);
	}
}

function writeAgents(agentsPath: string, content: string): void {
	try {
		mkdirSync(dirname(agentsPath), { recursive: true });
		writeFileSync(agentsPath, content, "utf8");
	} catch (error) {
		throw new DistributeError(`Unable to write ${agentsPath}: ${errorDetail(error)}`);
	}
}
