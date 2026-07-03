import type { StringSelectMenuInteraction } from "discord.js";
import { buildRenameModal } from "../../embeds/index.js";

export async function handleStorageRenameSelect(
	interaction: StringSelectMenuInteraction,
): Promise<void> {
	const slot = interaction.values[0];
	await interaction.showModal(buildRenameModal(slot));
}
