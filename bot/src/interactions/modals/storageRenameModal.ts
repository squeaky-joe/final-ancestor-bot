import { MessageFlags, type ModalSubmitInteraction } from "discord.js";
import { getSteam64 } from "../../db/index.js";
import { buildStorageResultEmbed } from "../../embeds/index.js";
import type { FinalAncestorClient } from "../../classes/Client.js";

const NOT_LINKED =
	"You haven't linked your Steam account yet.\nUse the **Link Steam ID** button first.";

const SLOT_RE = /^[\w-]{1,32}$/;
const PREFIX = "storage_rename_modal:";

export async function handleStorageRenameModal(
	interaction: ModalSubmitInteraction,
): Promise<void> {
	const oldSlot = interaction.customId.slice(PREFIX.length);

	const steam64 = await getSteam64(interaction.user.id);
	if (!steam64) {
		await interaction.reply({ content: NOT_LINKED, flags: MessageFlags.Ephemeral });
		return;
	}

	const rawNew = interaction.fields.getTextInputValue("new_slot_name");
	const newSlot = rawNew.trim().replace(/\s+/g, "_");

	if (!SLOT_RE.test(newSlot)) {
		await interaction.reply({
			content:
				"❌ Invalid slot name. Use letters, numbers, hyphens, and underscores only (max 32 chars).",
			flags: MessageFlags.Ephemeral,
		});
		return;
	}

	if (newSlot === oldSlot) {
		await interaction.reply({
			content: "❌ New name is the same as the current name.",
			flags: MessageFlags.Ephemeral,
		});
		return;
	}

	await interaction.deferReply({ flags: MessageFlags.Ephemeral });
	const client = interaction.client as FinalAncestorClient;

	try {
		const result = await client.ipc.sendAndAwaitSubMod("dino_rename", steam64, {
			args: [oldSlot, newSlot],
		});
		await interaction.editReply({
			embeds: [
				buildStorageResultEmbed(
					result.ok ? "📝 Slot Renamed" : "Rename Failed",
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
