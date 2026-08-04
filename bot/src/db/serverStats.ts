import { eq } from "drizzle-orm";
import { db } from "./index.js";
import { serverStatsConfig } from "../db/schema.js";

const CONFIG_ROW_ID = "default";

export async function getServerStatsConfig() {
	const [cfg] = await db
		.select()
		.from(serverStatsConfig)
		.where(eq(serverStatsConfig.id, CONFIG_ROW_ID))
		.limit(1);

	return cfg;
}

export async function setupServerStatsChannel(channelId: string) {
	// Insert or update the server stats configuration
	await db
		.insert(serverStatsConfig)
		.values({
			id: CONFIG_ROW_ID,
			channelId,
			updatedAt: new Date(),
		})
		.onConflictDoUpdate({
			target: serverStatsConfig.id,
			set: { channelId, updatedAt: new Date() },
		});
}

export async function updateServerStatsMessage(messageId: string) {
	await db
		.update(serverStatsConfig)
		.set({ messageId, updatedAt: new Date() })
		.where(eq(serverStatsConfig.id, CONFIG_ROW_ID));
}