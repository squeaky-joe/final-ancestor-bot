import crypto from "crypto";
import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";
import { REST, Routes } from "discord.js";
import { config } from "../config.js";
import type { Command } from "../classes/Command.js";
import type { Logger } from "../classes/Logger.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const HASH_FILE = path.join(__dirname, "..", "..", ".command-hash");

export async function registerCommands(commands: Command[], logger: Logger): Promise<void> {
	const body = commands.map((c) => c.data.toJSON());
	const hash = crypto.createHash("sha1").update(JSON.stringify(body)).digest("hex");

	let lastHash = "";
	try {
		lastHash = fs.readFileSync(HASH_FILE, "utf8").trim();
	} catch {
		// first run
	}

	if (lastHash === hash) {
		logger.info(`${body.length} command(s) unchanged — skipping sync`);
		return;
	}

	const rest = new REST().setToken(config.discordToken);
	const route = config.guildId
		? Routes.applicationGuildCommands(config.clientId, config.guildId)
		: Routes.applicationCommands(config.clientId);

	try {
		await rest.put(route, { body });
		fs.writeFileSync(HASH_FILE, hash, "utf8");
		logger.success(
			`Synced ${body.length} command(s)${config.guildId ? ` to guild ${config.guildId}` : " globally"}`,
		);
	} catch (err) {
		logger.error("Command sync failed:", err);
	}
}
