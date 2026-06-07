import { type ButtonInteraction, MessageFlags } from "discord.js";
import { getSteam64 } from "../../db/index.js";
import { buildStorageResultEmbed } from "../../embeds/index.js";
import type { FinalAncestorClient } from "../../classes/Client.js";

const NOT_LINKED =
	"You haven't linked your Steam account yet.\nUse the **Link Steam ID** button first.";

export async function handleStorageRetrieve(interaction: ButtonInteraction): Promise<void> {
	const steam64 = await getSteam64(interaction.user.id);
	if (!steam64) {
		await interaction.reply({ content: NOT_LINKED, flags: MessageFlags.Ephemeral });
		return;
	}

	await interaction.deferReply({ flags: MessageFlags.Ephemeral });
	const client = interaction.client as FinalAncestorClient;

	try {
		const result = await client.ipc.sendAndAwaitSubMod("dino_retrieve", steam64, {
			args: ["default"],
		});
		await interaction.editReply({
			embeds: [
				buildStorageResultEmbed(
					result.ok ? "📦 Dino Retrieved" : "Retrieve Failed",
					result.ok,
					result.msg,
				),
			],
		});
	} catch (e) {
		await interaction.editReply(`⚠️ IPC error: ${e instanceof Error ? e.message : String(e)}`);
	}
}
