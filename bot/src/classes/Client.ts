import { Client, Collection, GatewayIntentBits } from "discord.js";
import { config } from "../config.js";
import { IpcClient } from "../ipc/Client.js";
import { getCommands } from "../utils/getCommands.js";
import { getListeners } from "../utils/getListeners.js";
import { Logger } from "./Logger.js";
import type { Command } from "./Command.js";

export class FinalAncestorClient extends Client {
	public readonly commands = new Collection<string, Command>();
	public readonly logger = new Logger();
	public readonly ipc = new IpcClient();

	constructor() {
		super({ intents: [GatewayIntentBits.Guilds] });
	}

	async start(): Promise<void> {
		await this.loadListeners();
		await this.loadCommands();

		process.on("SIGINT", () => {
			this.ipc.stop();
			this.destroy();
			process.exit(0);
		});

		await this.login(config.discordToken);
	}

	private async loadCommands(): Promise<void> {
		const commands = await getCommands();
		for (const command of commands) {
			this.commands.set(command.data.name, command);
		}
		this.logger.info(`Loaded ${commands.length} command(s)`);
	}

	private async loadListeners(): Promise<void> {
		const listeners = await getListeners();
		for (const listener of listeners) {
			if (listener.once) {
				this.once(listener.name, (...args) =>
					// biome-ignore lint/suspicious/noExplicitAny: discord.js variadic events
					(listener.execute as (...a: any[]) => void)(...args),
				);
			} else {
				this.on(listener.name, (...args) =>
					// biome-ignore lint/suspicious/noExplicitAny: discord.js variadic events
					(listener.execute as (...a: any[]) => void)(...args),
				);
			}
		}
		this.logger.info(`Loaded ${listeners.length} listener(s)`);
	}
}
