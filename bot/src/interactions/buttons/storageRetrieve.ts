import { type ButtonInteraction, EmbedBuilder, MessageFlags } from "discord.js";
import { getSteam64 } from "../../db/index.js";
import { buildSlotSelectRow, type SlotEntry } from "../../embeds/index.js";
import type { FinalAncestorClient } from "../../classes/Client.js";

const NOT_LINKED =
	"You haven't linked your Steam account yet.\nUse the **Link Steam ID** button first.";

export async function handleStorageRetrieve(
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
		const [connResult, listResult] = await Promise.all([
			client.ipc.sendAndAwaitSubMod("dino_connected", steam64),
			client.ipc.sendAndAwaitSubMod("dino_list", steam64),
		]);

		if (!connResult.ok) {
			await interaction.editReply({
				embeds: [
					new EmbedBuilder()
						.setColor(0xed4245)
						.setTitle("Not Connected")
						.setDescription(connResult.msg || "You are not connected to the server."),
				],
			});
			return;
		}

		let slots: SlotEntry[] = [];
		try {
			slots = JSON.parse(listResult.msg) as SlotEntry[];
		} catch {
			await interaction.editReply("Received malformed list from server.");
			return;
		}

		if (slots.length === 0) {
			await interaction.editReply("You have no parked dinos to retrieve.");
			return;
		}

		await interaction.editReply({
			content: "Select a dino to retrieve:",
			components: [buildSlotSelectRow(slots)],
		});
	} catch (e) {
		await interaction.editReply(
			`⚠️ IPC error: ${e instanceof Error ? e.message : String(e)}`,
		);
	}
}
