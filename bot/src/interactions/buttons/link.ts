import {
	ActionRowBuilder,
	type ButtonInteraction,
	ModalBuilder,
	TextInputBuilder,
	TextInputStyle,
} from "discord.js";

export async function handleLinkButton(interaction: ButtonInteraction): Promise<void> {
	const modal = new ModalBuilder().setCustomId("link_modal").setTitle("Link Your Steam Account");

	const input = new TextInputBuilder()
		.setCustomId("steam64_input")
		.setLabel("Steam64 ID (17-digit number)")
		.setStyle(TextInputStyle.Short)
		.setPlaceholder("76561198XXXXXXXXX")
		.setMinLength(17)
		.setMaxLength(17)
		.setRequired(true);

	modal.addComponents(new ActionRowBuilder<TextInputBuilder>().addComponents(input));
	await interaction.showModal(modal);
}
