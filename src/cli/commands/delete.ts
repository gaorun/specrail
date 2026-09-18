import { rmSync } from "node:fs";
import { createInterface } from "node:readline/promises";
import { SpecIndex } from "../../core/index.ts";
import { parseCommandArgs, rootFrom, UsageError } from "../args.ts";
import { print, printJson } from "../out.ts";

export async function run(argv: string[]): Promise<number> {
	const { values, positionals } = parseCommandArgs(argv, {
		yes: { type: "boolean" },
	});
	const id = positionals[0];
	if (id === undefined) throw new UsageError("delete requires an id argument.");
	const index = new SpecIndex(rootFrom(values));
	const path = index.pathForId(id);
	if (path === undefined) {
		process.stderr.write(`No spec with id "${id}".\n`);
		return 2;
	}
	if (values.yes !== true) {
		if (!process.stdin.isTTY) {
			process.stderr.write("Refusing to delete without --yes (non-interactive).\n");
			return 2;
		}
		if (!(await confirm(`Delete ${path} (id: ${id})? [y/N] `))) return 0;
	}
	try {
		rmSync(index.absPath(path));
	} catch (err) {
		process.stderr.write(
			`Failed to delete ${path}: ${err instanceof Error ? err.message : String(err)}\n`,
		);
		return 2;
	}
	const details = { id, path };
	if (values.json === true) printJson(details);
	else print(`Deleted ${path} (id: ${id}).`);
	return 0;
}

async function confirm(question: string): Promise<boolean> {
	const rl = createInterface({ input: process.stdin, output: process.stdout });
	try {
		const answer = await rl.question(question);
		return answer.trim().toLowerCase() === "y";
	} catch {
		return false;
	} finally {
		rl.close();
	}
}
