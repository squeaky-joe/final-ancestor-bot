import { type ButtonInteraction, MessageFlags } from "discord.js";
import { getSteam64 } from "../../db/index.js";
import { buildSlotSelectRow, type SlotEntry } from "../../embeds/index.js";
import type { FinalAncestorClient } from "../../classes/Client.js";

const NOT_LINKED =
	"You haven't linked your Steam account yet.\nUse the **Link Steam ID** button first.";

export async function handleStorageRename(
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

		let slots: SlotEntry[] = [];
		try {
			slots = JSON.parse(result.msg) as SlotEntry[];
		} catch {
			await interaction.editReply("Received malformed list from server.");
			return;
		}

		if (slots.length === 0) {
			await interaction.editReply("You have no parked dinos to rename.");
			return;
		}

		await interaction.editReply({
			content: "Select a slot to rename:",
			components: [buildSlotSelectRow(slots, "storage_rename_select", "Select a slot to rename…")],
		});
	} catch (e) {
		await interaction.editReply(
			`⚠️ IPC error: ${e instanceof Error ? e.message : String(e)}`,
		);
	}
}
