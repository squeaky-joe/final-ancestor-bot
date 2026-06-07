import {
	ActionRowBuilder,
	ButtonBuilder,
	ButtonStyle,
	EmbedBuilder,
} from "discord.js";

export function buildLinkPanelEmbed(): EmbedBuilder {
	return new EmbedBuilder()
		.setColor(0x5865f2)
		.setTitle("🔗 Link Your Steam Account")
		.setDescription(
			"To use dino storage and other server features through Discord, " +
				"link your Steam64 ID to your account.\n\n" +
				"**How to find your Steam64 ID:**\n" +
				"> Visit **steamid.io**, enter your Steam profile URL, and copy the **steamID64** value.",
		)
		.setFooter({
			text: "You only need to link once. Click the button below to get started.",
		});
}

export function buildLinkPanelRow(): ActionRowBuilder<ButtonBuilder> {
	return new ActionRowBuilder<ButtonBuilder>().addComponents(
		new ButtonBuilder()
			.setCustomId("link_steam")
			.setLabel("Link Steam ID")
			.setStyle(ButtonStyle.Primary)
			.setEmoji("🔗"),
	);
}
