import {
	ActionRowBuilder,
	ButtonBuilder,
	ButtonStyle,
	EmbedBuilder,
	ModalBuilder,
	StringSelectMenuBuilder,
	StringSelectMenuOptionBuilder,
	TextInputBuilder,
	TextInputStyle,
} from "discord.js";

// ---- Panel ----

export function buildStoragePanelEmbed(): EmbedBuilder {
	return new EmbedBuilder()
		.setColor(0x2b2d31)
		.setTitle("🦕 Dino Storage")
		.setDescription(
			"Manage your dinosaur directly from Discord.\n" +
				"**You must be logged into the server for these actions to work.**",
		)
		.addFields(
			{
				name: "🅿️ Park",
				value:
					"Saves your current dino. You'll be prompted to name the slot.\n*Requires 75%+ growth.*",
				inline: false,
			},
			{
				name: "📦 Retrieve",
				value:
					"Restores a parked dino. Select the slot, then spawn the **same species** in-game first.",
				inline: false,
			},
			{
				name: "📋 List",
				value: "Shows all your parked dinos and their mutations.",
				inline: false,
			},
			{
				name: "📝 Rename",
				value: "Rename one of your stored slots.",
				inline: false,
			},
			{
				name: "⚔️ Slay",
				value: "Immediately kills your current dinosaur.",
				inline: false,
			},
		)
		.setFooter({
			text: "Use the Link Steam ID button if you haven't linked yet.",
		});
}

export function buildStoragePanelRow(): ActionRowBuilder<ButtonBuilder> {
	return new ActionRowBuilder<ButtonBuilder>().addComponents(
		new ButtonBuilder()
			.setCustomId("storage_park")
			.setLabel("Park")
			.setStyle(ButtonStyle.Success)
			.setEmoji("🅿️"),
		new ButtonBuilder()
			.setCustomId("storage_retrieve")
			.setLabel("Retrieve")
			.setStyle(ButtonStyle.Primary)
			.setEmoji("📦"),
		new ButtonBuilder()
			.setCustomId("storage_list")
			.setLabel("List")
			.setStyle(ButtonStyle.Secondary)
			.setEmoji("📋"),
		new ButtonBuilder()
			.setCustomId("storage_rename")
			.setLabel("Rename")
			.setStyle(ButtonStyle.Secondary)
			.setEmoji("📝"),
		new ButtonBuilder()
			.setCustomId("storage_slay")
			.setLabel("Slay")
			.setStyle(ButtonStyle.Danger)
			.setEmoji("⚔️"),
	);
}

// ---- Modals ----

export function buildParkModal(): ModalBuilder {
	return new ModalBuilder()
		.setCustomId("storage_park_modal")
		.setTitle("Park Your Dino")
		.addComponents(
			new ActionRowBuilder<TextInputBuilder>().addComponents(
				new TextInputBuilder()
					.setCustomId("slot_name")
					.setLabel("Slot name")
					.setStyle(TextInputStyle.Short)
					.setPlaceholder("e.g. main, juvi, prime")
					.setValue("default")
					.setMinLength(1)
					.setMaxLength(32)
					.setRequired(true),
			),
		);
}

export function buildRenameModal(oldSlot: string): ModalBuilder {
	return new ModalBuilder()
		.setCustomId(`storage_rename_modal:${oldSlot}`)
		.setTitle(`Rename "${oldSlot}"`)
		.addComponents(
			new ActionRowBuilder<TextInputBuilder>().addComponents(
				new TextInputBuilder()
					.setCustomId("new_slot_name")
					.setLabel("New slot name")
					.setStyle(TextInputStyle.Short)
					.setValue(oldSlot)
					.setMinLength(1)
					.setMaxLength(32)
					.setRequired(true),
			),
		);
}

// ---- Result embeds ----

export function buildStorageResultEmbed(
	title: string,
	ok: boolean,
	msg: string,
): EmbedBuilder {
	return new EmbedBuilder()
		.setColor(ok ? 0x57f287 : 0xed4245)
		.setTitle(title)
		.setDescription(msg || (ok ? "Done." : "Unknown error."));
}

export function buildSlayConfirmEmbed(): {
	embed: EmbedBuilder;
	row: ActionRowBuilder<ButtonBuilder>;
} {
	const embed = new EmbedBuilder()
		.setColor(0xffa500)
		.setTitle("⚠️ Confirm Slay")
		.setDescription(
			"This will **immediately kill** your current dinosaur.\nAre you sure?",
		);

	const row = new ActionRowBuilder<ButtonBuilder>().addComponents(
		new ButtonBuilder()
			.setCustomId("storage_slay_confirm")
			.setLabel("Yes, slay my dino")
			.setStyle(ButtonStyle.Danger)
			.setEmoji("⚔️"),
	);

	return { embed, row };
}

// ---- Slot select menu ----

export interface SlotEntry {
	slot: string;
	classPath: string;
	growth: number;
	capturedAt: number;
	mutations?: {
		Slot1?: string;
		Slot2?: string;
		Slot3?: string;
		Slot4?: string;
	};
}

export function buildSlotSelectRow(
	slots: SlotEntry[],
	customId = "storage_retrieve_slot",
	placeholder = "Select a dino…",
): ActionRowBuilder<StringSelectMenuBuilder> {
	return new ActionRowBuilder<StringSelectMenuBuilder>().addComponents(
		new StringSelectMenuBuilder()
			.setCustomId(customId)
			.setPlaceholder(placeholder)
			.addOptions(
				slots.map((s) =>
					new StringSelectMenuOptionBuilder()
						.setLabel(`${s.slot} — ${speciesName(s.classPath)}`)
						.setDescription(
							`${Math.round(s.growth * 100)}% growth · Parked ${formatTs(s.capturedAt)}`,
						)
						.setValue(s.slot),
				),
			),
	);
}

// ---- List embed ----

export function speciesName(classPath: string): string {
	const m = classPath.match(/BP_(.+?)\./);
	if (!m) return classPath || "Unknown";
	return m[1].replace(/_C$/, "").replace(/_/g, " ");
}

export function growthBar(growth: number): string {
	const pct = Math.round(growth * 100);
	const filled = Math.round(pct / 10);
	return `${"█".repeat(filled)}${"░".repeat(10 - filled)} ${pct}%`;
}

export function formatTs(ts: number): string {
	return new Date(ts * 1000).toLocaleString("en-US", {
		month: "short",
		day: "numeric",
		hour: "2-digit",
		minute: "2-digit",
	});
}

function mutationLabel(path: string): string {
	const base = path.split("/").pop() ?? path;
	return base.replace(/^BP_M_/, "").replace(/_C$/, "").replace(/_/g, " ");
}

export function buildListEmbed(steam64: string, slots: SlotEntry[]): EmbedBuilder {
	const embed = new EmbedBuilder()
		.setColor(0x5865f2)
		.setTitle("📋 Your Parked Dinos")
		.setFooter({ text: `Steam: ${steam64}` });

	for (const s of slots) {
		const activeMuts = [s.mutations?.Slot1, s.mutations?.Slot2, s.mutations?.Slot3, s.mutations?.Slot4]
			.filter((m): m is string => !!m)
			.map(mutationLabel);

		const mutLine =
			activeMuts.length > 0 ? `**Mutations:** ${activeMuts.join(", ")}` : "**Mutations:** none";

		embed.addFields({
			name: `${s.slot} — ${speciesName(s.classPath)}`,
			value: `${growthBar(s.growth)}\n${mutLine}\nParked: ${formatTs(s.capturedAt)}`,
			inline: false,
		});
	}

	return embed;
}
