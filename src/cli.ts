#!/usr/bin/env node
import { main } from "./cli/main.ts";

process.stdout.on("error", (error: NodeJS.ErrnoException) => {
	if (error.code === "EPIPE") process.exit(0);
	throw error;
});

process.exitCode = await main(process.argv.slice(2));
