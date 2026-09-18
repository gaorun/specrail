import { DistributeError } from "../distribute/config.ts";
import { HelpRequested, UsageError, VersionRequested } from "./args.ts";
import * as create from "./commands/create.ts";
import * as del from "./commands/delete.ts";
import * as graph from "./commands/graph.ts";
import * as grep from "./commands/grep.ts";
import * as init from "./commands/init.ts";
import * as list from "./commands/list.ts";
import * as show from "./commands/show.ts";
import * as sync from "./commands/sync.ts";
import * as update from "./commands/update.ts";
import * as validate from "./commands/validate.ts";
import { print } from "./out.ts";
import { packageVersion } from "./version.ts";

interface Command {
	name: string;
	summary: string;
	run(argv: string[]): Promise<number>;
}

const COMMANDS: readonly Command[] = [
	{
		name: "init",
		summary: "install skills and commands into assistant config (--tools, --rule)",
		run: init.run,
	},
	{
		name: "sync",
		summary: "refresh generated files and remove deselected tool outputs",
		run: sync.run,
	},
	{ name: "list", summary: "list spec nodes (--type, --tag, --json)", run: list.run },
	{ name: "show", summary: "show one spec by id (--json)", run: show.run },
	{
		name: "grep",
		summary:
			"search specs (--regex, --ignore-case, --type, --tag, --parent, --depends-on, --limit)",
		run: grep.run,
	},
	{ name: "graph", summary: "walk a graph slice (--direction, --depth, --edge)", run: graph.run },
	{ name: "create", summary: "create a spec file", run: create.run },
	{ name: "update", summary: "edit a spec's frontmatter", run: update.run },
	{ name: "delete", summary: "delete a spec file (--yes)", run: del.run },
	{ name: "validate", summary: "validate the spec graph (--json)", run: validate.run },
];

export async function main(argv: string[]): Promise<number> {
	const [command, ...args] = argv;
	if (command === undefined || command === "--help" || command === "-h") {
		printHelp();
		return 0;
	}
	if (command === "--version" || command === "-v") {
		print(packageVersion());
		return 0;
	}
	const entry = COMMANDS.find((candidate) => candidate.name === command);
	if (entry === undefined) {
		process.stderr.write(`Unknown command: ${command}\n`);
		return 2;
	}
	try {
		return await entry.run(args);
	} catch (err) {
		if (err instanceof HelpRequested) {
			printHelp();
			return 0;
		}
		if (err instanceof VersionRequested) {
			print(packageVersion());
			return 0;
		}
		if (err instanceof UsageError || err instanceof DistributeError) {
			process.stderr.write(`${err.message}\n`);
			return 2;
		}
		throw err;
	}
}

function printHelp(): void {
	print(`specrail ${packageVersion()} — spec-graph CLI with cross-assistant workflow skills`);
	for (const { name, summary } of COMMANDS) print(`  ${name.padEnd(9)} ${summary}`);
}
