import { EmbedBuilder, SlashCommandBuilder } from "discord.js";
import { v4 as uuidv4 } from "uuid";
import { and, eq } from "drizzle-orm";
import { Command } from "../../classes/index.js";
import { getSteam64, db } from "../../db/index.js";
import { skinPresets } from "../../db/schema.js";
import type { SkinColors } from "../../db/schema.js";
import type { FinalAncestorClient } from "../../classes/Client.js";

const SLOT_CHOICES = [
	{ name: "Body", value: "body" },
	{ name: "Markings", value: "markings" },
	{ name: "Flank", value: "flank" },
	{ name: "Underbelly", value: "underbelly" },
	{ name: "Detail", value: "detail" },
	{ name: "Eyes", value: "eyes" },
	{ name: "Breed / Display", value: "breed" },
	{ name: "All slots", value: "all" },
];

function parseColorComponent(raw: string): number | null {
	const n = parseFloat(raw);
	if (Number.isNaN(n)) return null;
	return n > 1
		? Math.max(0, Math.min(1, n / 255))
		: Math.max(0, Math.min(1, n));
}

export default new Command({
	data: new SlashCommandBuilder()
		.setName("skin")
		.setDescription("Manage your dino's skin colors")
		.addSubcommand((s) =>
			s
				.setName("set")
				.setDescription("Set a color slot on your live dino")
				.addStringOption((o) =>
					o
						.setName("slot")
						.setDescription("Which slot to change")
						.setRequired(true)
						.addChoices(...SLOT_CHOICES),
				)
				.addNumberOption((o) =>
					o.setName("r").setDescription("Red (0-1 or 0-255)").setRequired(true),
				)
				.addNumberOption((o) =>
					o
						.setName("g")
						.setDescription("Green (0-1 or 0-255)")
						.setRequired(true),
				)
				.addNumberOption((o) =>
					o
						.setName("b")
						.setDescription("Blue (0-1 or 0-255)")
						.setRequired(true),
				),
		)
		.addSubcommand((s) =>
			s.setName("reset").setDescription("Remove your skin override"),
		)
		.addSubcommand((s) =>
			s
				.setName("preset-save")
				.setDescription("Save a named skin preset")
				.addStringOption((o) =>
					o.setName("name").setDescription("Preset name").setRequired(true),
				)
				.addStringOption((o) =>
					o
						.setName("colors")
						.setDescription("JSON colors object")
						.setRequired(true),
				),
		)
		.addSubcommand((s) =>
			s
				.setName("preset-apply")
				.setDescription("Apply a saved skin preset to your live dino")
				.addStringOption((o) =>
					o.setName("name").setDescription("Preset name").setRequired(true),
				),
		)
		.addSubcommand((s) =>
			s.setName("preset-list").setDescription("List your saved skin presets"),
		),

	async execute(interaction) {
		const sub = interaction.options.getSubcommand();
		const client = interaction.client as FinalAncestorClient;
		const steam64 = await getSteam64(interaction.user.id);

		if (!steam64) {
			await interaction.reply({
				content:
					"You haven't linked your Steam account yet.\nUse the **Link Steam ID** button first.",
				ephemeral: true,
			});
			return;
		}

		if (sub === "set") {
			const slot = interaction.options.getString("slot", true);
			const rc = parseColorComponent(
				String(interaction.options.getNumber("r", true)),
			);
			const gc = parseColorComponent(
				String(interaction.options.getNumber("g", true)),
			);
			const bc = parseColorComponent(
				String(interaction.options.getNumber("b", true)),
			);

			if (rc === null || gc === null || bc === null) {
				await interaction.reply({
					content: "Invalid color values.",
					ephemeral: true,
				});
				return;
			}

			await interaction.deferReply({ ephemeral: true });

			try {
				const args =
					slot === "all"
						? {
								customizer: Object.fromEntries(
									[
										"BodyColor",
										"MarkingsColor",
										"FlankColor",
										"UnderbellyColor",
										"Detail1Color",
										"EyesColor",
										"MaleDisplayColor",
									].map((f) => [f, { r: rc, g: gc, b: bc, a: 1.0 }]),
								),
							}
						: { field: slot, r: rc, g: gc, b: bc };

				const result = await client.ipc.send("skin", steam64, args);
				const colorInt =
					Math.round(rc * 255) * 65536 +
					Math.round(gc * 255) * 256 +
					Math.round(bc * 255);
				await interaction.editReply({
					embeds: [
						new EmbedBuilder()
							.setColor(result.ok ? colorInt || 0x57f287 : 0xed4245)
							.setTitle(result.ok ? "Skin Updated" : "Skin Update Failed")
							.setDescription(
								result.msg ||
									(result.ok ? "Color applied to your dino." : "Unknown error"),
							),
					],
				});
			} catch (e) {
				await interaction.editReply(
					`⚠️ IPC error: ${e instanceof Error ? e.message : String(e)}`,
				);
			}
			return;
		}

		if (sub === "reset") {
			await interaction.deferReply({ ephemeral: true });
			try {
				const result = await client.ipc.send("skin", steam64, {
					field: "reset",
				});
				await interaction.editReply(
					result.ok ? "Skin override removed." : `Failed: ${result.msg}`,
				);
			} catch (e) {
				await interaction.editReply(
					`⚠️ IPC error: ${e instanceof Error ? e.message : String(e)}`,
				);
			}
			return;
		}

		if (sub === "preset-save") {
			const name = interaction.options.getString("name", true);
			let colors: SkinColors;
			try {
				colors = JSON.parse(interaction.options.getString("colors", true));
			} catch {
				await interaction.reply({
					content: "Invalid JSON for colors.",
					ephemeral: true,
				});
				return;
			}
			await db
				.insert(skinPresets)
				.values({ id: uuidv4(), discordId: interaction.user.id, name, colors });
			await interaction.reply({
				content: `Preset **${name}** saved.`,
				ephemeral: true,
			});
			return;
		}

		if (sub === "preset-apply") {
			const name = interaction.options.getString("name", true);
			const [preset] = await db
				.select()
				.from(skinPresets)
				.where(
					and(
						eq(skinPresets.discordId, interaction.user.id),
						eq(skinPresets.name, name),
					),
				)
				.limit(1);

			if (!preset) {
				await interaction.reply({
					content: `No preset named **${name}** found.`,
					ephemeral: true,
				});
				return;
			}

			await interaction.deferReply({ ephemeral: true });
			try {
				const result = await client.ipc.send("skin", steam64, {
					customizer: preset.colors,
				});
				await interaction.editReply(
					result.ok ? `Preset **${name}** applied.` : `Failed: ${result.msg}`,
				);
			} catch (e) {
				await interaction.editReply(
					`⚠️ IPC error: ${e instanceof Error ? e.message : String(e)}`,
				);
			}
			return;
		}

		if (sub === "preset-list") {
			const presets = await db
				.select({ name: skinPresets.name })
				.from(skinPresets)
				.where(eq(skinPresets.discordId, interaction.user.id));

			if (presets.length === 0) {
				await interaction.reply({
					content: "You have no saved skin presets.",
					ephemeral: true,
				});
				return;
			}

			await interaction.reply({
				embeds: [
					new EmbedBuilder()
						.setColor(0x5865f2)
						.setTitle("Your Skin Presets")
						.setDescription(presets.map((p) => `• **${p.name}**`).join("\n")),
				],
				ephemeral: true,
			});
		}
	},
});
