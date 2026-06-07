import {
	EmbedBuilder,
	MessageFlags,
	type ModalSubmitInteraction,
} from "discord.js";
import { db } from "../../db/index.js";
import { users } from "../../db/schema.js";

export async function handleLinkModal(
	interaction: ModalSubmitInteraction,
): Promise<void> {
	const steam64 = interaction.fields.getTextInputValue("steam64_input").trim();

	if (!/^\d{17}$/.test(steam64)) {
		await interaction.reply({
			content: "❌ Invalid Steam64 ID — must be exactly 17 digits.",
			flags: MessageFlags.Ephemeral,
		});
		return;
	}

	await db
		.insert(users)
		.values({ id: interaction.user.id, steam64, updatedAt: new Date() })
		.onConflictDoUpdate({
			target: users.id,
			set: { steam64, updatedAt: new Date() },
		});

	const embed = new EmbedBuilder()
		.setColor(0x57f287)
		.setTitle("✅ Account Linked")
		.setDescription(
			`Steam64 \`${steam64}\` linked to ${interaction.user}.\n\n` +
				"You can now use the **Dino Storage** panel.",
		);

	await interaction.reply({ embeds: [embed], flags: MessageFlags.Ephemeral });
}
