import {
	ActionRowBuilder,
	ButtonBuilder,
	ButtonStyle,
	EmbedBuilder,
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
					"Saves your current dino and sends you back to spawn.\n*Requires 75%+ growth.*",
				inline: false,
			},
			{
				name: "📦 Retrieve",
				value:
					"Restores your last parked dino. Spawn the **same species** in-game first, then click.",
				inline: false,
			},
			{
				name: "📋 List",
				value: "Shows your currently parked dinos.",
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
			.setCustomId("storage_slay")
			.setLabel("Slay")
			.setStyle(ButtonStyle.Danger)
			.setEmoji("⚔️"),
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

// ---- List embed helpers ----

export interface SlotEntry {
	slot: string;
	classPath: string;
	growth: number;
	capturedAt: number;
}

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

export function buildListEmbed(
	steam64: string,
	slots: SlotEntry[],
): EmbedBuilder {
	const embed = new EmbedBuilder()
		.setColor(0x5865f2)
		.setTitle("📋 Your Parked Dinos")
		.setFooter({ text: `Steam: ${steam64}` });

	for (const s of slots) {
		embed.addFields({
			name: `Slot: ${s.slot} — ${speciesName(s.classPath)}`,
			value: `${growthBar(s.growth)}\nParked: ${formatTs(s.capturedAt)}`,
			inline: false,
		});
	}

	return embed;
}
