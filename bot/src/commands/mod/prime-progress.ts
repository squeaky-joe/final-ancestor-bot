import { EmbedBuilder, SlashCommandBuilder } from "discord.js";
import { Command } from "../../classes/index.js";
import { getSteam64 } from "../../db/index.js";
import type { FinalAncestorClient } from "../../classes/Client.js";

export default new Command({
	data: new SlashCommandBuilder()
		.setName("prime-progress")
		.setDescription("Check your current prime eligibility progress"),

	async execute(interaction) {
		const client = interaction.client as FinalAncestorClient;
		const steam64 = await getSteam64(interaction.user.id);

		if (!steam64) {
			await interaction.reply({
				content:
					"You haven't linked your Steam account yet.\nUse the **Link Steam ID** button first.",
				ephemeral: true,
			});
			return;
		}

		await interaction.deferReply({ ephemeral: true });

		try {
			// Send a command to CommandBridge to get prime progress
			// We'll use a special verb that calls the PrimeNotify mod's getPlayerProgress function
			const result = await client.ipc.sendAndAwaitSubMod("prime_progress", steam64, {});
			
			if (result.ok && result.msg) {
				// Parse the JSON response from the mod
				let progressData;
				try {
					progressData = JSON.parse(result.msg);
				} catch (e) {
					console.error("Failed to parse prime progress data:", e);
					await interaction.editReply({
						content: "Error parsing progress data.",
					});
					return;
				}
				
				// Build the embed with progress information
				const embed = new EmbedBuilder()
					.setTitle("Prime Progress")
					.setColor(0x5865f2)
					.setDescription(`**Conditions Met:** ${progressData.conditionsMet}/${progressData.totalConditions}`)
					.addFields(
						{
							name: "Eligibility Status",
							value: progressData.isEligible 
								? "✅ You are eligible for Prime Elder!" 
								: "❌ Not yet eligible (need 5+ conditions)",
							inline: true
						},
						{
							name: "Zone Progress",
							value: `Migration: ${progressData.zoneCounts?.migration || 0}/2\nPatrol: ${progressData.zoneCounts?.patrol || 0}/4`,
							inline: true
						}
					);

				// Add conditions to the embed
				const conditionFields = progressData.conditions?.map((cond: any) => ({
					name: `${cond.completed ? '✅' : '❌'} ${cond.name}`,
					value: `${cond.description}\n**Status:** ${cond.completed ? 'Completed' : 'Not yet completed'}`,
					inline: false
				})) || [];

				if (conditionFields.length > 0) {
					embed.addFields(...conditionFields.slice(0, 5)); // Show first 5 conditions max
				}

				await interaction.editReply({
					embeds: [embed]
				});
			} else {
				await interaction.editReply({
					content: `Failed to get prime progress: ${result.msg || "Unknown error"}`,
				});
			}
		} catch (e) {
			console.error("Error getting prime progress:", e);
			await interaction.editReply(
				`⚠️ Error: ${e instanceof Error ? e.message : String(e)}`,
			);
		}
	},
});