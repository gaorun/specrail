import { spawnSync } from "node:child_process";
import {
	chmodSync,
	cpSync,
	existsSync,
	mkdirSync,
	mkdtempSync,
	readFileSync,
	renameSync,
	rmSync,
	writeFileSync,
} from "node:fs";
import { dirname, join, resolve } from "node:path";
import { parseArgs } from "node:util";
import pkg from "../package.json";
import { readSkills } from "../src/distribute/generate.ts";

const { values } = parseArgs({
	args: process.argv.slice(2),
	options: { current: { type: "boolean" }, outdir: { type: "string" } },
});
const runtimeVersion = pkg.packageManager.replace("bun@", "");
if (Bun.version !== runtimeVersion) {
	throw new Error(`Plugin builds require Bun ${runtimeVersion}; found ${Bun.version}`);
}

const root = resolve(import.meta.dir, "..");
const targets = values.current
	? [`${process.platform === "win32" ? "windows" : process.platform}-${process.arch}`]
	: ["darwin-arm64", "darwin-x64", "linux-arm64", "linux-x64", "windows-arm64", "windows-x64"];
const destination = resolve(
	values.outdir ??
		(values.current ? join(root, "dist/plugin-current/specrail") : join(root, "plugins/specrail")),
);
if (existsSync(destination) && !existsSync(join(destination, "runtime.json"))) {
	throw new Error(`Refusing to replace a non-build directory: ${destination}`);
}
mkdirSync(dirname(destination), { recursive: true });
const staging = mkdtempSync(join(dirname(destination), ".specrail-build-"));
const output = join(staging, "specrail");

try {
	mkdirSync(join(output, "libexec"), { recursive: true });
	for (const target of targets) {
		const binary = join(
			output,
			"libexec",
			`specrail-${target}${target.startsWith("windows-") ? ".exe" : ""}`,
		);
		const build = spawnSync(
			process.execPath,
			[
				"build",
				join(root, "src/cli.ts"),
				"--root",
				root,
				"--compile",
				`--target=bun-${target}`,
				"--asset",
				join(root, "skills"),
				"--no-compile-autoload-dotenv",
				"--no-compile-autoload-bunfig",
				"--no-compile-autoload-tsconfig",
				"--no-compile-autoload-package-json",
				"--outfile",
				binary,
			],
			{ cwd: staging, stdio: "inherit" },
		);
		if (build.status !== 0) throw new Error(`Standalone build failed for ${target}`);
		chmodSync(binary, 0o755);
	}

	for (const assistant of ["claude", "qoder"]) {
		const dir = `.${assistant}-plugin`;
		const manifest = JSON.parse(readFileSync(join(root, dir, "plugin.json"), "utf8"));
		mkdirSync(join(output, dir));
		writeFileSync(
			join(output, dir, "plugin.json"),
			`${JSON.stringify({ ...manifest, version: pkg.version }, null, 2)}\n`,
		);
		const marketplace = JSON.parse(readFileSync(join(root, dir, "marketplace.json"), "utf8"));
		marketplace.plugins[0].source = "./";
		writeFileSync(
			join(output, dir, "marketplace.json"),
			`${JSON.stringify(marketplace, null, 2)}\n`,
		);
	}
	for (const skill of readSkills(join(root, "skills"))) {
		cpSync(join(root, "skills", skill.name), join(output, "skills", skill.name), {
			recursive: true,
		});
	}
	for (const file of ["bin", "README.md", "LICENSE", "NOTICE"]) {
		cpSync(join(root, file), join(output, file), { recursive: true });
	}
	mkdirSync(join(output, "licenses"));
	cpSync(
		join(root, "licenses", `bun-${runtimeVersion}.txt`),
		join(output, "licenses", `bun-${runtimeVersion}.txt`),
	);
	cpSync(join(root, "node_modules/yaml/LICENSE"), join(output, "licenses/yaml-LICENSE"));
	chmodSync(join(output, "bin/specrail"), 0o755);
	writeFileSync(
		join(output, "runtime.json"),
		`${JSON.stringify({ runtime: "bun", version: runtimeVersion, targets }, null, 2)}\n`,
	);
	rmSync(destination, { recursive: true, force: true });
	renameSync(output, destination);
} finally {
	rmSync(staging, { recursive: true, force: true });
}
console.log(`Plugin built at ${destination}`);
