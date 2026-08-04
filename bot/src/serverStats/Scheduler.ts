import { EmbedBuilder, type TextChannel } from "discord.js";
import { config } from "../config.js";
import type { FinalAncestorClient } from "../classes/Client.js";
import { getServerStatsConfig, updateServerStatsMessage } from "../db/serverStats.js";

interface ServerStatsSnapshot {
	timestamp: number;
	playerCount: number;
	speciesDistribution: Record<string, number>;
	dietTypes: Record<string, number>;
}

let timer: ReturnType<typeof setInterval> | null = null;

export function startServerStatsScheduler(client: FinalAncestorClient): void {
	void runPipeline(client);
	timer = setInterval(
		() => void runPipeline(client),
		config.serverStats.intervalMs,
	);
	client.logger.info(
		`Server stats scheduler started — updating every ${config.serverStats.intervalMs / 60_000} min`,
	);
}

export function stopServerStatsScheduler(): void {
	if (timer) clearInterval(timer);
}

// Posts a fresh message immediately (used by the /server-stats setup command).
export async function postServerStats(
	client: FinalAncestorClient,
	channelId: string,
): Promise<void> {
	const channel = (await client.channels.fetch(channelId)) as TextChannel;
	const embed = await buildEmbed(client);
	const msg = await channel.send({ embeds: [embed] });
	await updateServerStatsMessage(msg.id);
}

async function runPipeline(client: FinalAncestorClient): Promise<void> {
	const cfg = await getServerStatsConfig();
	if (!cfg?.channelId) return;

	try {
		const embed = await buildEmbed(client);
		const channel = (await client.channels.fetch(cfg.channelId)) as TextChannel;

		if (cfg.messageId) {
			try {
				const existing = await channel.messages.fetch(cfg.messageId);
				await existing.edit({ embeds: [embed] });
				return;
			} catch {
				client.logger.warn(
					"Server stats: previous message not found, posting new one",
				);
			}
		}

		const msg = await channel.send({ embeds: [embed] });
		await updateServerStatsMessage(msg.id);
	} catch (e) {
		client.logger.error("Server stats pipeline error:", e);
	}
}

async function fetchSnapshot(
	client: FinalAncestorClient,
): Promise<ServerStatsSnapshot | null> {
	try {
		const result = await client.ipc.sendAndAwaitSubMod("server_stats", "", {});
		if (!result.ok) return null;
		return JSON.parse(result.msg) as ServerStatsSnapshot;
	} catch (e) {
		client.logger.warn(
			`Server stats: IPC request failed — ${e instanceof Error ? e.message : String(e)}`,
		);
		return null;
	}
}

async function buildEmbed(client: FinalAncestorClient): Promise<EmbedBuilder> {
	const snapshot = await fetchSnapshot(client);

	if (!snapshot) {
		return new EmbedBuilder()
			.setTitle("📊 Server Statistics")
			.setDescription(
				"⚠️ Could not reach the game server. Is it online and are the mods loaded?",
			)
			.setColor(0xed4245)
			.setTimestamp();
	}

	const speciesLines = Object.entries(snapshot.speciesDistribution)
		.sort(([, a], [, b]) => b - a)
		.map(([name, count]) => `${name}: ${count}`);

	const dietLines = [
		`Carnivores: ${snapshot.dietTypes.carnivore ?? 0}`,
		`Herbivores: ${snapshot.dietTypes.herbivore ?? 0}`,
		`Omnivores: ${snapshot.dietTypes.omnivore ?? 0}`,
	];

	return new EmbedBuilder()
		.setTitle("📊 Server Statistics")
		.setColor(0x5865f2)
		.addFields(
			{
				name: "Player Count",
				value: `${snapshot.playerCount} player${snapshot.playerCount === 1 ? "" : "s"} online`,
				inline: true,
			},
			{
				name: "Species Distribution",
				value: speciesLines.length > 0 ? speciesLines.join("\n") : "No players online",
				inline: true,
			},
			{
				name: "Diet Types",
				value: dietLines.join("\n"),
				inline: false,
			},
		)
		.setTimestamp(snapshot.timestamp * 1000);
}
