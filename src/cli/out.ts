export function print(text: string): void {
	process.stdout.write(`${text}\n`);
}

export function printJson(value: unknown): void {
	process.stdout.write(`${JSON.stringify(value, null, 2)}\n`);
}
