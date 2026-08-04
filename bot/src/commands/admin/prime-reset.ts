import {
	EmbedBuilder,
	MessageFlags,
	PermissionFlagsBits,
	SlashCommandBuilder,
} from "discord.js";
import { Command } from "../../classes/index.js";
import { getSteam64 } from "../../db/index.js";
import type { FinalAncestorClient } from "../../classes/Client.js";

export default new Command({
	data: new SlashCommandBuilder()
		.setName("prime-reset")
		.setDescription("Reset a player's prime eligibility conditions back to 0")
		.setDefaultMemberPermissions(PermissionFlagsBits.Administrator)
		.addUserOption((o) =>
			o
				.setName("user")
				.setDescription("The player to reset")
				.setRequired(true),
		),

	async execute(interaction) {
		const client = interaction.client as FinalAncestorClient;
		const targetUser = interaction.options.getUser("user", true);

		const steam64 = await getSteam64(targetUser.id);
		if (!steam64) {
			await interaction.reply({
				content: `❌ ${targetUser.username} hasn't linked their Steam account.`,
				flags: MessageFlags.Ephemeral,
			});
			return;
		}

		await interaction.deferReply({ flags: MessageFlags.Ephemeral });

		try {
			// "unprime" is a direct CommandBridge verb (not routed to a sub-mod
			// inbox), so it resolves on the first IPC result — use send(), not
			// sendAndAwaitSubMod() (which would wait forever for a second,
			// source-tagged result that never comes).
			const result = await client.ipc.send("unprime", steam64, {});

			await interaction.editReply({
				embeds: [
					new EmbedBuilder()
						.setColor(result.ok ? 0x57f287 : 0xed4245)
						.setTitle(result.ok ? "Prime Conditions Reset" : "Reset Failed")
						.setDescription(
							result.ok
								? `All 10 prime conditions for **${targetUser.username}** have been cleared.`
								: result.msg ||
									"Unknown error — the player may need to be online in-game.",
						),
				],
			});
		} catch (e) {
			await interaction.editReply(
				`⚠️ Error: ${e instanceof Error ? e.message : String(e)}`,
			);
		}
	},
});
