import { eq } from "drizzle-orm";
import { drizzle } from "drizzle-orm/postgres-js";
import postgres from "postgres";
import { config } from "../config.js";
import * as schema from "./schema.js";
import { guildConfig, users } from "./schema.js";

const client = postgres(config.databaseUrl);
export const db = drizzle(client, { schema });

export type DB = typeof db;

export async function getSteam64(discordId: string): Promise<string | null> {
	const [row] = await db
		.select({ steam64: users.steam64 })
		.from(users)
		.where(eq(users.id, discordId))
		.limit(1);
	return row?.steam64 ?? null;
}

export interface GuildConfig {
	adminRoleId: string | null;
	modRoleId: string | null;
}

export async function getGuildConfig(guildId: string): Promise<GuildConfig> {
	const [row] = await db
		.select({ adminRoleId: guildConfig.adminRoleId, modRoleId: guildConfig.modRoleId })
		.from(guildConfig)
		.where(eq(guildConfig.guildId, guildId))
		.limit(1);
	return row ?? { adminRoleId: null, modRoleId: null };
}
