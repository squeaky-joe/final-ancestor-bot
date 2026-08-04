import { EmbedBuilder, SlashCommandBuilder } from "discord.js";
import { Command } from "../../classes/index.js";
import { setupServerStatsChannel, getServerStatsConfig } from "../../db/serverStats.js";
import type { FinalAncestorClient } from "../../classes/Client.js";

export default new Command({
	data: new SlashCommandBuilder()
		.setName("server-stats")
		.setDescription("Setup server statistics channel")
		.addChannelOption((option) =>
			option
				.setName("channel")
				.setDescription("Channel to post server stats in")
				.setRequired(true)
				.addChannelTypes(1), // Text channel only
		),

	async execute(interaction) {
		const client = interaction.client as FinalAncestorClient;
		
		// Only allow admins to use this command
		if (!interaction.memberPermissions?.has("Administrator")) {
			await interaction.reply({
				content: "You must be an administrator to use this command.",
				ephemeral: true,
			});
			return;
		}

		const channel = interaction.options.getChannel("channel");
		
		if (!channel || channel.type !== 1) { // Text channel
			await interaction.reply({
				content: "Please specify a valid text channel.",
				ephemeral: true,
			});
			return;
		}

		await interaction.deferReply({ ephemeral: true });

		try {
			await setupServerStatsChannel(channel.id);
			
			const embed = new EmbedBuilder()
				.setTitle("✅ Server Stats Channel Setup")
				.setDescription(`Server statistics will now be posted in <#${channel.id}>`)
				.setColor(0x57f287)
				.setTimestamp();

			await interaction.editReply({
				embeds: [embed]
			});
			
			// Immediately post the stats message
			await postServerStats(client, channel.id);
		} catch (e) {
			console.error("Error setting up server stats channel:", e);
			await interaction.editReply({
				content: `❌ Error setting up server stats channel: ${e instanceof Error ? e.message : String(e)}`,
				ephemeral: true,
			});
		}
	},
});

// Function to post server stats (called by scheduler and command)
export async function postServerStats(client: FinalAncestorClient, channelId?: string) {
	try {
		const config = await getServerStatsConfig();
		if (!config?.channelId && !channelId) return;
		
		const targetChannelId = channelId || config.channelId;
		const channel = await client.channels.fetch(targetChannelId);
		
		if (!channel?.isTextBased()) return;
		
		// This would be where we'd query the actual server data
		// For now, we'll create a placeholder message that shows what data will be tracked
		
		const embed = new EmbedBuilder()
			.setTitle("📊 Server Statistics")
			.setDescription("Real-time server statistics will appear here.")
			.setColor(0x5865f2)
			.addFields(
				{
					name: "Player Count",
					value: "Loading...",
					inline: true
				},
				{
					name: "Species Distribution",
					value: "Loading...",
					inline: true
				},
				{
					name: "Diet Types",
					value: "Loading...",
					inline: false
				}
			)
			.setTimestamp();
			
		const message = await channel.send({ embeds: [embed] });
		
		if (config && !config.messageId) {
			await updateServerStatsMessage(message.id);
		}
	} catch (e) {
		console.error("Error posting server stats:", e);
	}
}