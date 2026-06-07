import {
	EmbedBuilder,
	MessageFlags,
	PermissionFlagsBits,
	SlashCommandBuilder,
	type GuildMember,
} from "discord.js";
import { Command } from "../../classes/index.js";
import { getGuildConfig } from "../../db/index.js";
import { hasRole } from "../../utils/index.js";

export default new Command({
	data: new SlashCommandBuilder()
		.setName("kick")
		.setDescription("Kick a member from the server")
		.setDefaultMemberPermissions(PermissionFlagsBits.KickMembers)
		.addUserOption((o) =>
			o
			.setName("user")
			.setDescription("The member to kick")
			.setRequired(true),
		)
		.addStringOption((o) =>
			o
				.setName("reason")
				.setDescription("Reason for the kick")
				.setRequired(false),
		),

	async execute(interaction) {
		const cfg = await getGuildConfig(interaction.guildId!);
		const executor = await interaction.guild?.members.fetch(
			interaction.user.id,
		);

		if (!executor || !hasRole(executor, cfg.modRoleId ?? cfg.adminRoleId)) {
			await interaction.reply({
				embeds: [
					new EmbedBuilder()
						.setColor(0xed4245)
						.setDescription(
							"❌ You don't have permission to use this command.",
						),
				],
				flags: MessageFlags.Ephemeral,
			});
			return;
		}

		const target = interaction.options.getMember("user") as GuildMember | null;
		const reason =
			interaction.options.getString("reason") ?? "No reason provided";

		if (!target) {
			await interaction.reply({
				embeds: [
					new EmbedBuilder()
						.setColor(0xed4245)
						.setDescription("❌ That user is not in this server."),
				],
				flags: MessageFlags.Ephemeral,
			});
			return;
		}

		if (target.id === interaction.user.id) {
			await interaction.reply({
				embeds: [
					new EmbedBuilder()
						.setColor(0xed4245)
						.setDescription("❌ You can't kick yourself."),
				],
				flags: MessageFlags.Ephemeral,
			});
			return;
		}

		if (!target.kickable) {
			await interaction.reply({
				embeds: [
					new EmbedBuilder()
						.setColor(0xed4245)
						.setDescription(
							"❌ I can't kick that member. They may have a higher role than me.",
						),
				],
				flags: MessageFlags.Ephemeral,
			});
			return;
		}

		await target.kick(`${interaction.user.tag}: ${reason}`);

		await interaction.reply({
			embeds: [
				new EmbedBuilder()
					.setColor(0xffa500)
					.setAuthor({
						name: "Member Kicked",
						iconURL: target.user.displayAvatarURL({ size: 256 }),
					})
					.setThumbnail(target.user.displayAvatarURL({ size: 256 }))
					.addFields(
						{
							name: "Member",
							value: `${target.user.tag}\n<@${target.id}>`,
							inline: true,
						},
						{
							name: "Moderator",
							value: `${interaction.user.tag}\n<@${interaction.user.id}>`,
							inline: true,
						},
						{ name: "Reason", value: reason },
					)
					.setFooter({ text: `User ID: ${target.id}` })
					.setTimestamp(),
			],
		});
	},
});
