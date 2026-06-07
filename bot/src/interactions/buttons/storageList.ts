import { type ButtonInteraction, MessageFlags } from "discord.js";
import { getSteam64 } from "../../db/index.js";
import { buildListEmbed, type SlotEntry } from "../../embeds/index.js";
import type { FinalAncestorClient } from "../../classes/Client.js";

const NOT_LINKED =
	"You haven't linked your Steam account yet.\nUse the **Link Steam ID** button first.";

export async function handleStorageList(
	interaction: ButtonInteraction,
): Promise<void> {
	const steam64 = await getSteam64(interaction.user.id);
	if (!steam64) {
		await interaction.reply({
			content: NOT_LINKED,
			flags: MessageFlags.Ephemeral,
		});
		return;
	}

	await interaction.deferReply({ flags: MessageFlags.Ephemeral });
	const client = interaction.client as FinalAncestorClient;

	try {
		const result = await client.ipc.sendAndAwaitSubMod("dino_list", steam64);

		if (!result.ok) {
			await interaction.editReply(`No parked dinos found: ${result.msg}`);
			return;
		}

		let slots: SlotEntry[] = [];
		try {
			slots = JSON.parse(result.msg) as SlotEntry[];
		} catch {
			await interaction.editReply("Received malformed list from server.");
			return;
		}

		if (slots.length === 0) {
			await interaction.editReply("You have no parked dinos.");
			return;
		}

		await interaction.editReply({ embeds: [buildListEmbed(steam64, slots)] });
	} catch (e) {
		await interaction.editReply(
			`⚠️ IPC error: ${e instanceof Error ? e.message : String(e)}`,
		);
	}
}
