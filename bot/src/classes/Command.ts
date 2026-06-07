import type {
	ChatInputCommandInteraction,
	SlashCommandBuilder,
	SlashCommandOptionsOnlyBuilder,
	SlashCommandSubcommandsOnlyBuilder,
} from "discord.js";

export interface CommandOptions {
	data:
		| SlashCommandBuilder
		| SlashCommandSubcommandsOnlyBuilder
		| SlashCommandOptionsOnlyBuilder
		| Omit<SlashCommandBuilder, "addSubcommand" | "addSubcommandGroup">;
	execute: (interaction: ChatInputCommandInteraction) => Promise<void>;
}

export class Command {
	public readonly data: CommandOptions["data"];
	public readonly execute: CommandOptions["execute"];

	constructor(options: CommandOptions) {
		this.data = options.data;
		this.execute = options.execute;
	}
}
