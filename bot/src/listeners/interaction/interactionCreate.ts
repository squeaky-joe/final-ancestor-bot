import { Listener } from "../../classes/index.js";
import { handleButton, handleModal } from "../../interactions/index.js";
import type { FinalAncestorClient } from "../../classes/Client.js";
import type { Interaction } from "discord.js";

export default new Listener({
	name: "interactionCreate",
	async execute(interaction: Interaction) {
		const client = interaction.client as FinalAncestorClient;

		if (interaction.isChatInputCommand()) {
			const command = client.commands.get(interaction.commandName);
			if (!command) return;
			try {
				await command.execute(interaction);
			} catch (err) {
				client.logger.error(`Command error [${interaction.commandName}]:`, err);
				const msg = { content: "An error occurred while running that command.", ephemeral: true };
				if (interaction.replied || interaction.deferred) {
					await interaction.followUp(msg);
				} else {
					await interaction.reply(msg);
				}
			}
			return;
		}

		if (interaction.isButton()) {
			await handleButton(interaction);
			return;
		}

		if (interaction.isModalSubmit()) {
			await handleModal(interaction);
		}
	},
});
