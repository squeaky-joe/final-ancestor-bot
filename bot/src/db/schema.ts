import {
	boolean,
	doublePrecision,
	integer,
	json,
	pgTable,
	serial,
	text,
	timestamp,
	uniqueIndex,
} from "drizzle-orm/pg-core";

export const users = pgTable(
	"users",
	{
		id: text("id").primaryKey(), // Discord user ID
		steam64: text("steam64").notNull(),
		linkedAt: timestamp("linked_at").defaultNow().notNull(),
		updatedAt: timestamp("updated_at").defaultNow().notNull(),
	},
	(t) => [uniqueIndex("users_steam64_idx").on(t.steam64)],
);

export const skinPresets = pgTable("skin_presets", {
	id: text("id").primaryKey(), // uuid
	discordId: text("discord_id")
		.notNull()
		.references(() => users.id, { onDelete: "cascade" }),
	name: text("name").notNull(),
	colors: json("colors").notNull().$type<SkinColors>(),
	createdAt: timestamp("created_at").defaultNow().notNull(),
});

export const bodyDropLog = pgTable("body_drop_log", {
	id: text("id").primaryKey(),
	discordId: text("discord_id").notNull(),
	steam64: text("steam64").notNull(),
	species: text("species").notNull(),
	growth: integer("growth").notNull(),
	x: integer("x").notNull(),
	y: integer("y").notNull(),
	z: integer("z").notNull(),
	success: boolean("success").notNull(),
	createdAt: timestamp("created_at").defaultNow().notNull(),
});

export const heatmapPositions = pgTable("heatmap_positions", {
	id: serial("id").primaryKey(),
	x: doublePrecision("x").notNull(),
	y: doublePrecision("y").notNull(),
	loggedAt: timestamp("logged_at").defaultNow().notNull(),
});

// Single-row config — id is always "default"
export const heatmapConfig = pgTable("heatmap_config", {
	id: text("id").primaryKey(),
	channelId: text("channel_id").notNull(),
	messageId: text("message_id"),
	updatedAt: timestamp("updated_at").defaultNow().notNull(),
});

// Per-guild role configuration
export const guildConfig = pgTable("guild_config", {
	guildId: text("guild_id").primaryKey(),
	// Role allowed to use admin/owner commands (e.g. /setup)
	adminRoleId: text("admin_role_id"),
	// Role allowed to use staff/moderator commands (e.g. /bodydrop)
	modRoleId: text("mod_role_id"),
	updatedAt: timestamp("updated_at").defaultNow().notNull(),
});

// ---- Types ----

export interface SkinColorRgba {
	r: number;
	g: number;
	b: number;
	a: number;
}

export interface SkinColors {
	BodyColor?: SkinColorRgba;
	MarkingsColor?: SkinColorRgba;
	FlankColor?: SkinColorRgba;
	UnderbellyColor?: SkinColorRgba;
	Detail1Color?: SkinColorRgba;
	EyesColor?: SkinColorRgba;
	MaleDisplayColor?: SkinColorRgba;
	SkinVariation?: number;
	PatternIndex?: number;
}
