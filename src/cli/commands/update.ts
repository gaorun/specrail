import { writeFileSync } from "node:fs";
import {
	type FrontmatterEdit,
	LIST_FIELDS,
	SpecIndex,
	updateFrontmatterText,
} from "../../core/index.ts";
import { parseCommandArgs, rootFrom, UsageError } from "../args.ts";
import { print, printJson } from "../out.ts";

function splitAssignment(raw: string, flag: string): { key: string; value: string } {
	const at = raw.indexOf("=");
	if (at <= 0) throw new UsageError(`--${flag} expects K=V, got "${raw}"`);
	return { key: raw.slice(0, at), value: raw.slice(at + 1) };
}

export async function run(argv: string[]): Promise<number> {
	const { values, positionals } = parseCommandArgs(argv, {
		set: { type: "string", multiple: true },
		remove: { type: "string", multiple: true },
		"add-list": { type: "string", multiple: true },
		"remove-list": { type: "string", multiple: true },
	});
	const id = positionals[0];
	if (id === undefined) throw new UsageError("update requires an id argument.");

	const set: Record<string, string> = {};
	for (const raw of values.set ?? []) {
		const { key, value } = splitAssignment(raw, "set");
		set[key] = value;
	}
	const remove = [...(values.remove ?? [])];
	const addList: Partial<Record<string, string[]>> = {};
	for (const raw of values["add-list"] ?? []) {
		const { key, value } = splitAssignment(raw, "add-list");
		const field = LIST_FIELDS.find((candidate) => candidate === key);
		if (field === undefined) {
			throw new UsageError(`--add-list supports only: ${LIST_FIELDS.join(", ")}`);
		}
		addList[field] = [...(addList[field] ?? []), value];
	}
	const removeList: Partial<Record<string, string[]>> = {};
	for (const raw of values["remove-list"] ?? []) {
		const { key, value } = splitAssignment(raw, "remove-list");
		const field = LIST_FIELDS.find((candidate) => candidate === key);
		if (field === undefined) {
			throw new UsageError(`--remove-list supports only: ${LIST_FIELDS.join(", ")}`);
		}
		removeList[field] = [...(removeList[field] ?? []), value];
	}

	const index = new SpecIndex(rootFrom(values));
	const record = index.recordForId(id);
	if (record === undefined) {
		process.stderr.write(`No spec with id "${id}".\n`);
		return 2;
	}
	const edit: FrontmatterEdit = { set, remove, addList, removeList };
	const result = updateFrontmatterText(record.content, edit);
	if ("error" in result) {
		process.stderr.write(`${result.error}\n`);
		return 2;
	}
	try {
		writeFileSync(record.abs, result.content, "utf8");
	} catch (err) {
		process.stderr.write(
			`Failed to write ${record.rel}: ${err instanceof Error ? err.message : String(err)}\n`,
		);
		return 2;
	}
	const details = { id, path: record.rel };
	if (values.json === true) printJson(details);
	else print(`Updated frontmatter of ${record.rel} (id: ${id}).`);
	return 0;
}
