import * as dotenv from "dotenv";
import path from "path";

dotenv.config();

function required(key: string): string {
	const val = process.env[key];
	if (!val) throw new Error(`Missing required env var: ${key}`);
	return val;
}

export const config = {
	discordToken: required("DISCORD_TOKEN"),
	clientId: required("DISCORD_CLIENT_ID"),
	guildId: process.env.DISCORD_GUILD_ID,
	databaseUrl: required("DATABASE_URL"),
	modsPath: process.env.MODS_PATH ?? path.join(process.cwd(), "mods_data"),
	adminRoleId: process.env.ADMIN_ROLE_ID,

	ipc: {
		commandBridgePath: () =>
			path.join(config.modsPath, "CommandBridge", "Saved"),
		commandsFile: () =>
			path.join(config.ipc.commandBridgePath(), "commands.ndjson"),
		resultsFile: () =>
			path.join(config.ipc.commandBridgePath(), "results.ndjson"),
		timeoutMs: 20_000,
		pollIntervalMs: 250,
	},

	heatmap: {
		positionsFile: () =>
			path.join(
				config.modsPath,
				"HeatmapCollector",
				"Saved",
				"positions.ndjson",
			),
		mapImagePath: process.env.HEATMAP_MAP_PATH ?? "",
		// World-space bounds of the map in UE units (centimeters).
		// Tune these to match Isla Nycta's actual extents.
		worldMinX: parseFloat(process.env.HEATMAP_MIN_X ?? "-176000"),
		worldMaxX: parseFloat(process.env.HEATMAP_MAX_X ?? "176000"),
		worldMinY: parseFloat(process.env.HEATMAP_MIN_Y ?? "-176000"),
		worldMaxY: parseFloat(process.env.HEATMAP_MAX_Y ?? "176000"),
		// How many hours of history to include in the heatmap
		retentionHours: parseInt(process.env.HEATMAP_RETENTION_HOURS ?? "24", 10),
		// How often the bot updates the heatmap embed (ms)
		intervalMs: 30 * 60 * 1000,
	},
} as const;
