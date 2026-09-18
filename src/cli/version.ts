import { readFileSync } from "node:fs";

const VERSION_SOURCES = ["../package.json", "../../package.json"];

export function packageVersion(): string {
	for (const source of VERSION_SOURCES) {
		try {
			const pkg = JSON.parse(readFileSync(new URL(source, import.meta.url), "utf8")) as {
				version: string;
			};
			return pkg.version;
		} catch {}
	}
	throw new Error("Unable to locate package.json to read the specrail version");
}
