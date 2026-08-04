import {
	ChannelType,
	MessageFlags,
	PermissionFlagsBits,
	SlashCommandBuilder,
} from "discord.js";
import { Command } from "../../classes/index.js";
import { setupServerStatsChannel } from "../../db/serverStats.js";
import { postServerStats } from "../../serverStats/index.js";
import { config } from "../../config.js";
import type { FinalAncestorClient } from "../../classes/Client.js";

export default new Command({
	data: new SlashCommandBuilder()
		.setName("server-stats")
		.setDescription("Setup server statistics channel")
		.setDefaultMemberPermissions(PermissionFlagsBits.Administrator)
		.addChannelOption((option) =>
			option
				.setName("channel")
				.setDescription("Channel to post server stats in")
				.setRequired(true)
				.addChannelTypes(ChannelType.GuildText),
		),

	async execute(interaction) {
		const client = interaction.client as FinalAncestorClient;
		const channel = interaction.options.getChannel("channel", true);

		await interaction.deferReply({ flags: MessageFlags.Ephemeral });

		try {
			await setupServerStatsChannel(channel.id);
			await postServerStats(client, channel.id);

			const minutes = config.serverStats.intervalMs / 60_000;
			await interaction.editReply(
				`✅ Server statistics will now be posted in <#${channel.id}>. ` +
					`It will auto-update every ${minutes} minute${minutes === 1 ? "" : "s"}.`,
			);
		} catch (e) {
			console.error("Error setting up server stats channel:", e);
			await interaction.editReply(
				`❌ Error setting up server stats channel: ${e instanceof Error ? e.message : String(e)}`,
			);
		}
	},
});
