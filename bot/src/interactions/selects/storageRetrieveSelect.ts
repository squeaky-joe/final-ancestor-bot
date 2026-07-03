import { type StringSelectMenuInteraction, MessageFlags } from "discord.js";
import { getSteam64 } from "../../db/index.js";
import { buildStorageResultEmbed } from "../../embeds/index.js";
import type { FinalAncestorClient } from "../../classes/Client.js";

const NOT_LINKED =
	"You haven't linked your Steam account yet.\nUse the **Link Steam ID** button first.";

export async function handleStorageRetrieveSlot(
	interaction: StringSelectMenuInteraction,
): Promise<void> {
	const steam64 = await getSteam64(interaction.user.id);
	if (!steam64) {
		await interaction.reply({
			content: NOT_LINKED,
			flags: MessageFlags.Ephemeral,
		});
		return;
	}

	const slot = interaction.values[0];
	await interaction.deferReply({ flags: MessageFlags.Ephemeral });
	const client = interaction.client as FinalAncestorClient;

	try {
		const result = await client.ipc.sendAndAwaitSubMod("dino_retrieve", steam64, {
			args: [slot],
		});

		if (result.ok) {
			client.ipc
				.sendAndAwaitSubMod("dino_delete", steam64, { args: [slot] })
				.catch(() => {});
		}

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
		await interaction.editReply(
			`⚠️ IPC error: ${e instanceof Error ? e.message : String(e)}`,
		);
	}
}
