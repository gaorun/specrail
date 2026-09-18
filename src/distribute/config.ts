import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { TOOLS, type Tool } from "./adapters.ts";

export class DistributeError extends Error {}

export function errorDetail(error: unknown): string {
	return error instanceof Error ? error.message : String(error);
}

export const CONFIG_DIR = ".specrail";
export const CONFIG_PATH = `${CONFIG_DIR}/config.json`;

export interface DistributeConfig {
	version: string;
	tools: Tool[];
	files: string[];
}

export function readConfig(root: string): DistributeConfig | undefined {
	const path = join(root, CONFIG_PATH);
	if (!existsSync(path)) return undefined;
	let parsed: unknown;
	try {
		parsed = JSON.parse(readFileSync(path, "utf8"));
	} catch (error) {
		throw new DistributeError(`Unable to read ${CONFIG_PATH}: ${errorDetail(error)}`);
	}
	return configFrom(parsed);
}

export function writeConfig(root: string, config: DistributeConfig): void {
	const path = join(root, CONFIG_PATH);
	try {
		mkdirSync(dirname(path), { recursive: true });
		writeFileSync(path, `${JSON.stringify(config, null, 2)}\n`, "utf8");
	} catch (error) {
		throw new DistributeError(`Unable to write ${CONFIG_PATH}: ${errorDetail(error)}`);
	}
}

function configFrom(parsed: unknown): DistributeConfig {
	if (typeof parsed !== "object" || parsed === null) {
		throw new DistributeError(`${CONFIG_PATH} must be a JSON object`);
	}
	const version = "version" in parsed ? parsed.version : undefined;
	const tools = "tools" in parsed ? parsed.tools : undefined;
	const files = "files" in parsed ? parsed.files : undefined;
	if (typeof version !== "string" || version === "") {
		throw new DistributeError(`${CONFIG_PATH} must declare a specrail version`);
	}
	if (!Array.isArray(tools) || !tools.every(isTool)) {
		throw new DistributeError(`${CONFIG_PATH} tools must come from: ${TOOLS.join(", ")}`);
	}
	if (!Array.isArray(files) || !files.every(isManifestPath)) {
		throw new DistributeError(`${CONFIG_PATH} files must be root-relative paths`);
	}
	return { version, tools, files };
}

function isTool(value: unknown): value is Tool {
	return TOOLS.some((candidate) => candidate === value);
}

function isManifestPath(value: unknown): value is string {
	if (typeof value !== "string" || value === "") return false;
	if (value.startsWith("/") || value.includes("\\")) return false;
	return !value.split("/").some((segment) => segment === "" || segment === "." || segment === "..");
}
