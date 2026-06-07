import fs from "fs";
import { sql } from "drizzle-orm";
import { config } from "../config.js";
import { db } from "../db/index.js";
import { heatmapPositions } from "../db/schema.js";

interface RawEntry {
	x: number;
	y: number;
	ts: number;
}

export async function collectPositions(): Promise<number> {
	const file = config.heatmap.positionsFile();

	if (!fs.existsSync(file)) return 0;

	let raw: string;
	try {
		raw = fs.readFileSync(file, "utf8");
		fs.writeFileSync(file, "", "utf8"); // clear immediately after read
	} catch (e) {
		console.warn("[heatmap:collector] Could not read/clear positions file:", e);
		return 0;
	}

	const lines = raw.split("\n").filter((l) => l.trim());
	if (lines.length === 0) return 0;

	const rows: { x: number; y: number; loggedAt: Date }[] = [];
	for (const line of lines) {
		try {
			const entry: RawEntry = JSON.parse(line);
			if (typeof entry.x === "number" && typeof entry.y === "number") {
				rows.push({ x: entry.x, y: entry.y, loggedAt: new Date(entry.ts * 1000) });
			}
		} catch {
			console.warn("[heatmap:collector] Skipping malformed line:", line);
		}
	}

	if (rows.length === 0) return 0;

	// Insert in chunks of 500 to avoid query size limits
	const CHUNK = 500;
	for (let i = 0; i < rows.length; i += CHUNK) {
		await db.insert(heatmapPositions).values(rows.slice(i, i + CHUNK));
	}

	console.log(`[heatmap:collector] Inserted ${rows.length} position(s)`);
	return rows.length;
}

export async function pruneOldPositions(): Promise<void> {
	const cutoff = new Date(Date.now() - config.heatmap.retentionHours * 60 * 60 * 1000);
	await db.delete(heatmapPositions).where(sql`${heatmapPositions.loggedAt} < ${cutoff}`);
}
