import {
	ChannelType,
	EmbedBuilder,
	MessageFlags,
	PermissionFlagsBits,
	SlashCommandBuilder,
	type TextChannel,
} from "discord.js";
import { eq } from "drizzle-orm";
import { Command } from "../../classes/index.js";
import { db } from "../../db/index.js";
import { guildConfig } from "../../db/schema.js";
import { buildLinkPanelEmbed, buildLinkPanelRow } from "../../embeds/index.js";
import { buildStoragePanelEmbed, buildStoragePanelRow } from "../../embeds/index.js";
import { setupHeatmapChannel } from "../../heatmap/index.js";
import type { FinalAncestorClient } from "../../classes/Client.js";

export default new Command({
	data: new SlashCommandBuilder()
		.setName("setup")
		.setDescription("Post persistent embeds into server channels")
		.setDefaultMemberPermissions(PermissionFlagsBits.Administrator)
		.addSubcommand((s) =>
			s
				.setName("link")
				.setDescription("Post the Steam account link embed")
				.addChannelOption((o) =>
					o
						.setName("channel")
						.setDescription("Channel to post in (defaults to current)")
						.addChannelTypes(ChannelType.GuildText)
						.setRequired(false),
				),
		)
		.addSubcommand((s) =>
			s
				.setName("storage")
				.setDescription("Post the dino storage panel embed")
				.addChannelOption((o) =>
					o
						.setName("channel")
						.setDescription("Channel to post in (defaults to current)")
						.addChannelTypes(ChannelType.GuildText)
						.setRequired(false),
				),
		)
		.addSubcommand((s) =>
			s
				.setName("heatmap")
				.setDescription("Post the activity heatmap embed and start auto-updates")
				.addChannelOption((o) =>
					o
						.setName("channel")
						.setDescription("Channel to post in (defaults to current)")
						.addChannelTypes(ChannelType.GuildText)
						.setRequired(false),
				),
		)
		.addSubcommand((s) =>
			s
				.setName("roles")
				.setDescription("Configure the admin and moderator roles for this server")
				.addRoleOption((o) =>
					o
						.setName("admin")
						.setDescription("Role that can use admin commands (e.g. /setup)")
						.setRequired(false),
				)
				.addRoleOption((o) =>
					o
						.setName("mod")
						.setDescription("Role that can use staff commands (e.g. /bodydrop)")
						.setRequired(false),
				),
		),

	async execute(interaction) {
		const sub = interaction.options.getSubcommand();
		const target =
			(interaction.options.getChannel("channel") as TextChannel | null) ??
			(interaction.channel as TextChannel);

		if (sub === "link") {
			await target.send({ embeds: [buildLinkPanelEmbed()], components: [buildLinkPanelRow()] });
			await interaction.reply({
				content: `Link embed posted in ${target}.`,
				flags: MessageFlags.Ephemeral,
			});
			return;
		}

		if (sub === "storage") {
			await target.send({
				embeds: [buildStoragePanelEmbed()],
				components: [buildStoragePanelRow()],
			});
			await interaction.reply({
				content: `Storage panel posted in ${target}.`,
				flags: MessageFlags.Ephemeral,
			});
			return;
		}

		if (sub === "heatmap") {
			await interaction.deferReply({ flags: MessageFlags.Ephemeral });
			try {
				const client = interaction.client as FinalAncestorClient;
				const { messageId } = await setupHeatmapChannel(client, target.id);
				await interaction.editReply(
					`🗺️ Heatmap posted in ${target} (message \`${messageId}\`). ` +
						"It will auto-update every 30 minutes.",
				);
			} catch (e) {
				await interaction.editReply(
					`❌ Failed to post heatmap: ${e instanceof Error ? e.message : String(e)}`,
				);
			}
			return;
		}

		if (sub === "roles") {
			const adminRole = interaction.options.getRole("admin");
			const modRole = interaction.options.getRole("mod");

			if (!adminRole && !modRole) {
				// Show current config
				const [current] = await db
					.select({
						adminRoleId: guildConfig.adminRoleId,
						modRoleId: guildConfig.modRoleId,
					})
					.from(guildConfig)
					.where(eq(guildConfig.guildId, interaction.guildId!))
					.limit(1);

				const embed = new EmbedBuilder()
					.setTitle("Role Configuration")
					.setColor(0x5865f2)
					.addFields(
						{
							name: "Admin Role",
							value: current?.adminRoleId ? `<@&${current.adminRoleId}>` : "_Not set — uses Discord Administrator permission_",
							inline: true,
						},
						{
							name: "Mod Role",
							value: current?.modRoleId ? `<@&${current.modRoleId}>` : "_Not set — no restriction_",
							inline: true,
						},
					)
					.setFooter({ text: "Use /setup roles admin: @role mod: @role to update" });

				await interaction.reply({ embeds: [embed], flags: MessageFlags.Ephemeral });
				return;
			}

			await db
				.insert(guildConfig)
				.values({
					guildId: interaction.guildId!,
					adminRoleId: adminRole?.id ?? null,
					modRoleId: modRole?.id ?? null,
				})
				.onConflictDoUpdate({
					target: guildConfig.guildId,
					set: {
						...(adminRole !== undefined ? { adminRoleId: adminRole?.id ?? null } : {}),
						...(modRole !== undefined ? { modRoleId: modRole?.id ?? null } : {}),
						updatedAt: new Date(),
					},
				});

			const lines: string[] = [];
			if (adminRole !== undefined) {
				lines.push(`**Admin role** → ${adminRole ? `<@&${adminRole.id}>` : "_cleared_"}`);
			}
			if (modRole !== undefined) {
				lines.push(`**Mod role** → ${modRole ? `<@&${modRole.id}>` : "_cleared_"}`);
			}

			await interaction.reply({
				content: `✅ Role configuration updated:\n${lines.join("\n")}`,
				flags: MessageFlags.Ephemeral,
			});
		}
	},
});
