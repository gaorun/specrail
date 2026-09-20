// plugins/specrail/bin 注入 pi 会话 PATH：让会话内可直接执行 specrail 命令
import { existsSync } from "node:fs";
import { delimiter, dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const binDir = join(dirname(fileURLToPath(import.meta.url)), "..", "plugins", "specrail", "bin");

export default function () {
  if (!existsSync(binDir)) return;
  const pathKey = Object.keys(process.env).find((key) => key.toLowerCase() === "path") ?? "PATH";
  const parts = (process.env[pathKey] ?? "").split(delimiter).filter(Boolean);
  if (parts.includes(binDir)) return;
  process.env[pathKey] = [binDir, ...parts].join(delimiter);
}
