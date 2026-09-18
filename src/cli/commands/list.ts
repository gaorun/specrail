import { FIELDS, list, SpecIndex } from "../../core/index.ts";
import { parseCommandArgs, rootFrom } from "../args.ts";
import { print, printJson } from "../out.ts";

export async function run(argv: string[]): Promise<number> {
	const { values } = parseCommandArgs(argv, {
		type: { type: "string" },
		tag: { type: "string" },
	});
	const graph = new SpecIndex(rootFrom(values)).graph();
	const nodes = [...graph.nodes.values()]
		.filter((node) => values.type === undefined || node.type === values.type)
		.filter(
			(node) =>
				values.tag === undefined || list(node.frontmatter, FIELDS.tags).includes(values.tag),
		)
		.sort((a, b) => a.path.localeCompare(b.path));
	if (values.json === true) {
		printJson(
			nodes.map((node) => ({ id: node.id, type: node.type, title: node.title, path: node.path })),
		);
		return 0;
	}
	for (const node of nodes) {
		print(`${node.id} [${node.type}]${node.title ? ` — ${node.title}` : ""} (${node.path})`);
	}
	return 0;
}
