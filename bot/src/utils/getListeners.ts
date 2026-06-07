import fs from "fs";
import path from "path";
import { fileURLToPath, pathToFileURL } from "url";
import type { Listener } from "../classes/Listener.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

export async function getListeners(): Promise<Listener[]> {
	const listenersDir = path.join(__dirname, "..", "listeners");
	const listeners: Listener[] = [];

	if (!fs.existsSync(listenersDir)) return listeners;

	const scan = async (dir: string) => {
		for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
			const full = path.join(dir, entry.name);
			if (entry.isDirectory()) {
				await scan(full);
			} else if (entry.isFile() && (entry.name.endsWith(".js") || entry.name.endsWith(".ts"))) {
				const mod = await import(pathToFileURL(full).href);
				if (mod.default && "name" in mod.default && "execute" in mod.default) {
					listeners.push(mod.default as Listener);
				}
			}
		}
	};

	await scan(listenersDir);
	return listeners;
}
