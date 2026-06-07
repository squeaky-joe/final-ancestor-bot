import { type ButtonInteraction, EmbedBuilder, MessageFlags } from "discord.js";
import { getSteam64 } from "../../db/index.js";
import type { FinalAncestorClient } from "../../classes/Client.js";

const NOT_LINKED =
	"You haven't linked your Steam account yet.\nUse the **Link Steam ID** button first.";

export async function handleStorageSlayConfirm(interaction: ButtonInteraction): Promise<void> {
	const steam64 = await getSteam64(interaction.user.id);
	if (!steam64) {
		await interaction.reply({ content: NOT_LINKED, flags: MessageFlags.Ephemeral });
		return;
	}

	await interaction.deferReply({ flags: MessageFlags.Ephemeral });
	const client = interaction.client as FinalAncestorClient;

	try {
		const result = await client.ipc.send("kill", steam64);
		const embed = new EmbedBuilder()
			.setColor(result.ok ? 0xed4245 : 0xffa500)
			.setTitle(result.ok ? "⚔️ Dino Slain" : "Slay Failed")
			.setDescription(result.msg || (result.ok ? "Your dinosaur has been slain." : "Unknown error."));

		await interaction.editReply({ embeds: [embed] });
	} catch (e) {
		await interaction.editReply(`⚠️ IPC error: ${e instanceof Error ? e.message : String(e)}`);
	}
}
