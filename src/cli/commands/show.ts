import {
	type Frontmatter,
	LINK_KINDS,
	type LinkKind,
	linkTargets,
	SpecIndex,
} from "../../core/index.ts";
import { parseCommandArgs, rootFrom, UsageError } from "../args.ts";
import { print, printJson } from "../out.ts";

interface ResolvedLink {
	kind: LinkKind;
	target: string;
	path: string | null;
}

interface GetDetails {
	id: string;
	type: string;
	title: string | undefined;
	path: string;
	frontmatter: Frontmatter;
	links: ResolvedLink[];
	reverseLinks: ResolvedLink[];
}

export async function run(argv: string[]): Promise<number> {
	const { values, positionals } = parseCommandArgs(argv, {});
	const id = positionals[0];
	if (id === undefined) throw new UsageError("show requires an id argument.");
	const graph = new SpecIndex(rootFrom(values)).graph();
	const node = graph.nodes.get(id);
	if (node === undefined) {
		process.stderr.write(`No spec with id "${id}".\n`);
		return 2;
	}

	const links: ResolvedLink[] = [];
	for (const kind of LINK_KINDS) {
		for (const target of linkTargets(node.frontmatter, kind)) {
			links.push({ kind, target, path: graph.nodes.get(target)?.path ?? null });
		}
	}
	const reverseLinks: ResolvedLink[] = [];
	for (const kind of LINK_KINDS) {
		for (const source of graph.reverse[kind].get(id) ?? []) {
			reverseLinks.push({ kind, target: source, path: graph.nodes.get(source)?.path ?? null });
		}
	}

	const details: GetDetails = {
		id: node.id,
		type: node.type,
		title: node.title,
		path: node.path,
		frontmatter: node.frontmatter,
		links,
		reverseLinks,
	};
	if (values.json === true) {
		printJson(details);
		return 0;
	}

	const fmtLink = (link: ResolvedLink) =>
		`  ${link.kind} -> ${link.target}${link.path ? ` (${link.path})` : " (missing)"}`;
	print(
		[
			`${node.id} [${node.type}]${node.title ? ` — ${node.title}` : ""}`,
			`path: ${node.path}`,
			links.length ? `links:\n${links.map(fmtLink).join("\n")}` : "links: (none)",
			reverseLinks.length
				? `referenced by:\n${reverseLinks.map(fmtLink).join("\n")}`
				: "referenced by: (none)",
		].join("\n"),
	);
	return 0;
}
