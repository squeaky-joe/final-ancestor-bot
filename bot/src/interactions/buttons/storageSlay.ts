import { type ButtonInteraction, MessageFlags } from "discord.js";
import { getSteam64 } from "../../db/index.js";
import { buildSlayConfirmEmbed } from "../../embeds/index.js";

const NOT_LINKED =
	"You haven't linked your Steam account yet.\nUse the **Link Steam ID** button first.";

export async function handleStorageSlay(interaction: ButtonInteraction): Promise<void> {
	const steam64 = await getSteam64(interaction.user.id);
	if (!steam64) {
		await interaction.reply({ content: NOT_LINKED, flags: MessageFlags.Ephemeral });
		return;
	}

	const { embed, row } = buildSlayConfirmEmbed();
	await interaction.reply({ embeds: [embed], components: [row], flags: MessageFlags.Ephemeral });
}
