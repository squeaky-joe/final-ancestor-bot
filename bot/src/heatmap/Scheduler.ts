import { AttachmentBuilder, EmbedBuilder, type TextChannel } from "discord.js";
import { eq } from "drizzle-orm";
import { config } from "../config.js";
import { db } from "../db/index.js";
import { heatmapConfig } from "../db/schema.js";
import type { FinalAncestorClient } from "../classes/Client.js";
import { collectPositions, pruneOldPositions } from "./Collector.js";
import { generateHeatmap } from "./Generator.js";

const CONFIG_ROW_ID = "default";
let timer: ReturnType<typeof setInterval> | null = null;

export function startHeatmapScheduler(client: FinalAncestorClient): void {
	void runPipeline(client);
	timer = setInterval(() => void runPipeline(client), config.heatmap.intervalMs);
	client.logger.info(
		`Heatmap scheduler started — updating every ${config.heatmap.intervalMs / 60_000} min`,
	);
}

export function stopHeatmapScheduler(): void {
	if (timer) clearInterval(timer);
}

export async function setupHeatmapChannel(
	client: FinalAncestorClient,
	channelId: string,
): Promise<{ messageId: string }> {
	const png = await generateHeatmap();
	const channel = (await client.channels.fetch(channelId)) as TextChannel;
	const msg = await channel.send({
		embeds: [buildEmbed()],
		files: [new AttachmentBuilder(png, { name: "heatmap.png" })],
	});

	await db
		.insert(heatmapConfig)
		.values({ id: CONFIG_ROW_ID, channelId, messageId: msg.id, updatedAt: new Date() })
		.onConflictDoUpdate({
			target: heatmapConfig.id,
			set: { channelId, messageId: msg.id, updatedAt: new Date() },
		});

	return { messageId: msg.id };
}

async function runPipeline(client: FinalAncestorClient): Promise<void> {
	const [cfg] = await db
		.select()
		.from(heatmapConfig)
		.where(eq(heatmapConfig.id, CONFIG_ROW_ID))
		.limit(1);

	if (!cfg) return;

	try {
		const collected = await collectPositions();
		await pruneOldPositions();
		const png = await generateHeatmap();

		const channel = (await client.channels.fetch(cfg.channelId)) as TextChannel;
		const embed = buildEmbed();
		const file = new AttachmentBuilder(png, { name: "heatmap.png" });

		if (cfg.messageId) {
			try {
				const existing = await channel.messages.fetch(cfg.messageId);
				await existing.edit({ embeds: [embed], files: [file] });
				client.logger.debug(`Heatmap updated (message ${cfg.messageId}, +${collected} pts)`);
				return;
			} catch {
				client.logger.warn("Heatmap: previous message not found, posting new one");
			}
		}

		const msg = await channel.send({ embeds: [embed], files: [file] });
		await db
			.update(heatmapConfig)
			.set({ messageId: msg.id, updatedAt: new Date() })
			.where(eq(heatmapConfig.id, CONFIG_ROW_ID));
		client.logger.info(`Heatmap: posted new message ${msg.id}`);
	} catch (e) {
		client.logger.error("Heatmap pipeline error:", e);
	}
}

function buildEmbed(): EmbedBuilder {
	return new EmbedBuilder()
		.setColor(0x2b2d31)
		.setTitle("🗺️ Server Activity Heatmap")
		.setDescription(
			`Showing player activity over the last **${config.heatmap.retentionHours} hours**.\n` +
				"Updates every **30 minutes** automatically.",
		)
		.setImage("attachment://heatmap.png")
		.setTimestamp();
}
