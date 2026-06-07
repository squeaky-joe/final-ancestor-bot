import fs from "fs";
import path from "path";
import { fileURLToPath, pathToFileURL } from "url";
import type { Command } from "../classes/Command.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

export async function getCommands(): Promise<Command[]> {
	const commandsDir = path.join(__dirname, "..", "commands");
	const commands: Command[] = [];

	if (!fs.existsSync(commandsDir)) return commands;

	const scan = async (dir: string) => {
		for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
			const full = path.join(dir, entry.name);
			if (entry.isDirectory()) {
				await scan(full);
			} else if (
				entry.isFile() &&
				(entry.name.endsWith(".js") || entry.name.endsWith(".ts"))
			) {
				const mod = await import(pathToFileURL(full).href);
				if (mod.default && "data" in mod.default && "execute" in mod.default) {
					commands.push(mod.default as Command);
				}
			}
		}
	};

	await scan(commandsDir);
	return commands;
}
