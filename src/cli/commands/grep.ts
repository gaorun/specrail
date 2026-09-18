import { type GrepResult, grepSpecs, SpecIndex } from "../../core/index.ts";
import { numberFrom, parseCommandArgs, rootFrom, UsageError } from "../args.ts";
import { print, printJson } from "../out.ts";

export async function run(argv: string[]): Promise<number> {
	const { values, positionals } = parseCommandArgs(argv, {
		regex: { type: "boolean" },
		"ignore-case": { type: "boolean" },
		type: { type: "string" },
		tag: { type: "string" },
		parent: { type: "string" },
		"depends-on": { type: "string" },
		limit: { type: "string" },
	});
	const pattern = positionals[0];
	if (pattern === undefined) throw new UsageError("grep requires a pattern argument.");
	const limit = numberFrom(values.limit, "limit");
	let result: GrepResult;
	try {
		result = grepSpecs(new SpecIndex(rootFrom(values)).contentEntries(), {
			pattern,
			...(values.regex !== undefined ? { regex: values.regex } : {}),
			...(values["ignore-case"] !== undefined ? { ignoreCase: values["ignore-case"] } : {}),
			...(values.type !== undefined ? { type: values.type } : {}),
			...(values.tag !== undefined ? { tag: values.tag } : {}),
			...(values.parent !== undefined ? { parent: values.parent } : {}),
			...(values["depends-on"] !== undefined ? { dependsOn: values["depends-on"] } : {}),
			...(limit !== undefined ? { limit } : {}),
		});
	} catch (err) {
		process.stderr.write(
			`Invalid search pattern: ${err instanceof Error ? err.message : String(err)}\n`,
		);
		return 2;
	}
	if (values.json === true) {
		printJson(result);
		return 0;
	}
	const { matches, truncated } = result;
	const header =
		matches.length === 0
			? "No matches."
			: `${matches.length} match(es)${truncated ? " (truncated)" : ""}:`;
	const body = matches.map((match) => `${match.path}:${match.line}: ${match.snippet}`).join("\n");
	print(`${header}\n${body}`.trimEnd());
	return 0;
}
