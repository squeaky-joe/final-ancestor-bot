import { EmbedBuilder, PermissionFlagsBits, SlashCommandBuilder } from "discord.js";
import { v4 as uuidv4 } from "uuid";
import { Command } from "../../classes/index.js";
import { getSteam64, getGuildConfig, db } from "../../db/index.js";
import { bodyDropLog } from "../../db/schema.js";
import { hasRole } from "../../utils/index.js";
import type { FinalAncestorClient } from "../../classes/Client.js";

const SPECIES_CHOICES = [
	{ name: "Tyrannosaurus", value: "Tyrannosaurus" },
	{ name: "Triceratops", value: "Triceratops" },
	{ name: "Allosaurus", value: "Allosaurus" },
	{ name: "Stegosaurus", value: "Stegosaurus" },
	{ name: "Carnotaurus", value: "Carnotaurus" },
	{ name: "Ceratosaurus", value: "Ceratosaurus" },
	{ name: "Deinosuchus", value: "Deinosuchus" },
	{ name: "Gallimimus", value: "Gallimimus" },
	{ name: "Troodon", value: "Troodon" },
	{ name: "Omniraptor", value: "Omniraptor" },
	{ name: "Dilophosaurus", value: "Dilophosaurus" },
	{ name: "Maiasaura", value: "Maiasaura" },
	{ name: "Tenontosaurus", value: "Tenontosaurus" },
	{ name: "Diabloceratops", value: "Diabloceratops" },
	{ name: "Pachycephalosaurus", value: "Pachycephalosaurus" },
	{ name: "Herrerasaurus", value: "Herrerasaurus" },
];

export default new Command({
	data: new SlashCommandBuilder()
		.setName("bodydrop")
		.setDescription("Body drop admin commands")
		.setDefaultMemberPermissions(PermissionFlagsBits.Administrator)
		.addSubcommand((s) =>
			s
				.setName("spawn")
				.setDescription("Spawn a corpse at coordinates or near a player")
				.addStringOption((o) =>
					o
						.setName("species")
						.setDescription("Species to spawn")
						.setRequired(true)
						.addChoices(...SPECIES_CHOICES),
				)
				.addNumberOption((o) =>
					o.setName("x").setDescription("World X coordinate").setRequired(true),
				)
				.addNumberOption((o) =>
					o.setName("y").setDescription("World Y coordinate").setRequired(true),
				)
				.addNumberOption((o) =>
					o.setName("z").setDescription("World Z coordinate").setRequired(true),
				)
				.addIntegerOption((o) =>
					o
						.setName("growth")
						.setDescription("Growth percent (1-100, default 100)")
						.setMinValue(1)
						.setMaxValue(100)
						.setRequired(false),
				)
				.addUserOption((o) =>
					o
						.setName("target")
						.setDescription("Spawn near this player (overrides X/Y/Z)")
						.setRequired(false),
				),
		)
		.addSubcommand((s) =>
			s.setName("status").setDescription("Check body drop system status"),
		),

	async execute(interaction) {
		const cfg = await getGuildConfig(interaction.guildId!);
		const member = await interaction.guild?.members.fetch(interaction.user.id);
		if (!member || !hasRole(member, cfg.modRoleId ?? cfg.adminRoleId)) {
			await interaction.reply({ content: "❌ You don't have permission to use this command.", flags: 64 });
			return;
		}

		const sub = interaction.options.getSubcommand();
		const client = interaction.client as FinalAncestorClient;

		if (sub === "spawn") {
			const species = interaction.options.getString("species", true);
			const x = interaction.options.getNumber("x", true);
			const y = interaction.options.getNumber("y", true);
			const z = interaction.options.getNumber("z", true);
			const growthPct = interaction.options.getInteger("growth") ?? 100;
			const targetUser = interaction.options.getUser("target");

			await interaction.deferReply();

			let targetSteam = "";
			if (targetUser) {
				const steam = await getSteam64(targetUser.id);
				if (!steam) {
					await interaction.editReply(`${targetUser.username} hasn't linked their Steam64 ID.`);
					return;
				}
				targetSteam = steam;
			}

			const adminSteam = (await getSteam64(interaction.user.id)) ?? "admin";

			let result;
			try {
				result = await client.ipc.sendAndAwaitSubMod("bodydrop", targetSteam || adminSteam, {
					args: [
						"spawn",
						species,
						String(x),
						String(y),
						String(z),
						String(growthPct / 100),
					],
				});
			} catch (e) {
				await interaction.editReply(
					`⚠️ IPC error: ${e instanceof Error ? e.message : String(e)}`,
				);
				return;
			}

			await db.insert(bodyDropLog).values({
				id: uuidv4(),
				discordId: interaction.user.id,
				steam64: adminSteam,
				species,
				growth: growthPct,
				x: Math.round(x),
				y: Math.round(y),
				z: Math.round(z),
				success: result.ok,
			});

			await interaction.editReply({
				embeds: [
					new EmbedBuilder()
						.setColor(result.ok ? 0x57f287 : 0xed4245)
						.setTitle(result.ok ? "Corpse Spawned" : "Spawn Failed")
						.addFields(
							{ name: "Species", value: species, inline: true },
							{ name: "Growth", value: `${growthPct}%`, inline: true },
							{
								name: "Location",
								value: `${Math.round(x)}, ${Math.round(y)}, ${Math.round(z)}`,
								inline: true,
							},
						)
						.setDescription(result.msg || (result.ok ? "Corpse has been spawned." : "Unknown error")),
				],
			});
			return;
		}

		if (sub === "status") {
			await interaction.deferReply({ ephemeral: true });
			try {
				const result = await client.ipc.sendAndAwaitSubMod("bodydrop", "", { args: ["status"] });
				await interaction.editReply({
					embeds: [
						new EmbedBuilder()
							.setColor(0x5865f2)
							.setTitle("BodyDrop Status")
							.setDescription(result.msg || "No status info available."),
					],
				});
			} catch (e) {
				await interaction.editReply(
					`⚠️ IPC error: ${e instanceof Error ? e.message : String(e)}`,
				);
			}
		}
	},
});
