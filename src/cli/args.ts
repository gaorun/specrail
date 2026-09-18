import { existsSync, statSync } from "node:fs";
import type { ParseArgsOptionsConfig } from "node:util";
import { parseArgs } from "node:util";

export class UsageError extends Error {}
export class HelpRequested extends Error {}
export class VersionRequested extends Error {}

export const GLOBAL_OPTIONS = {
	root: { type: "string" },
	json: { type: "boolean" },
	help: { type: "boolean", short: "h" },
	version: { type: "boolean", short: "v" },
} as const satisfies ParseArgsOptionsConfig;

export function parseCommandArgs<const Options extends ParseArgsOptionsConfig>(
	argv: string[],
	options: Options,
) {
	try {
		const parsed = parseArgs({
			args: argv,
			options: { ...GLOBAL_OPTIONS, ...options },
			allowPositionals: true,
			strict: true,
		});
		const flags: Record<string, unknown> = parsed.values;
		if (flags.help === true) throw new HelpRequested();
		if (flags.version === true) throw new VersionRequested();
		return parsed;
	} catch (err) {
		if (err instanceof HelpRequested || err instanceof VersionRequested) throw err;
		throw new UsageError(err instanceof Error ? err.message : String(err));
	}
}

export function rootFrom(values: { root?: string | undefined }): string {
	const root = values.root ?? process.cwd();
	if (!existsSync(root)) throw new UsageError(`Root directory does not exist: ${root}`);
	if (!statSync(root).isDirectory()) throw new UsageError(`Root is not a directory: ${root}`);
	return root;
}

export function numberFrom(value: string | undefined, flag: string): number | undefined {
	if (value === undefined) return undefined;
	const parsed = Number(value);
	if (!Number.isFinite(parsed)) throw new UsageError(`--${flag} must be a number, got "${value}"`);
	return parsed;
}
