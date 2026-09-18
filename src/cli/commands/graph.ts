import { graphSlice, LINK_KINDS, SLICE_DIRECTIONS, SpecIndex } from "../../core/index.ts";
import { numberFrom, parseCommandArgs, rootFrom, UsageError } from "../args.ts";
import { print, printJson } from "../out.ts";

export async function run(argv: string[]): Promise<number> {
	const { values, positionals } = parseCommandArgs(argv, {
		direction: { type: "string" },
		depth: { type: "string" },
		edge: { type: "string" },
	});
	const id = positionals[0];
	if (id === undefined) throw new UsageError("graph requires an id argument.");
	const direction = SLICE_DIRECTIONS.find((candidate) => candidate === values.direction);
	if (direction === undefined) {
		throw new UsageError(`--direction must be one of: ${SLICE_DIRECTIONS.join(", ")}`);
	}
	const edge =
		values.edge === undefined
			? undefined
			: LINK_KINDS.find((candidate) => candidate === values.edge);
	if (values.edge !== undefined && edge === undefined) {
		throw new UsageError(`--edge must be one of: ${LINK_KINDS.join(", ")}`);
	}
	const depth = numberFrom(values.depth, "depth");
	const graph = new SpecIndex(rootFrom(values)).graph();
	if (!graph.nodes.has(id)) {
		process.stderr.write(`No spec with id "${id}".\n`);
		return 2;
	}
	const slice = graphSlice(graph, {
		root: id,
		direction,
		...(depth !== undefined ? { depth } : {}),
		...(edge !== undefined ? { edge } : {}),
	});
	if (values.json === true) {
		printJson(slice);
		return 0;
	}
	const nodeLines = slice.nodes.map(
		(node) => `  ${node.id} [${node.type}]${node.title ? ` — ${node.title}` : ""} (${node.path})`,
	);
	const edgeLines = slice.edges.map((item) => `  ${item.from} --${item.kind}--> ${item.to}`);
	print(
		[
			`Slice of "${id}" (${direction}, depth ${depth ?? 1}):`,
			`nodes (${slice.nodes.length}):`,
			...nodeLines,
			`edges (${slice.edges.length}):`,
			...edgeLines,
			slice.missing.length ? `missing targets: ${slice.missing.join(", ")}` : "",
		]
			.filter(Boolean)
			.join("\n"),
	);
	return 0;
}
