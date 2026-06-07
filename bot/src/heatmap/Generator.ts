import fs from "fs";
import { sql } from "drizzle-orm";
import { createCanvas, loadImage, type Canvas } from "@napi-rs/canvas";
import { config } from "../config.js";
import { db } from "../db/index.js";
import { heatmapPositions } from "../db/schema.js";

const OUTPUT_SIZE = 1024;
const BLOB_RADIUS = 28;

// ---- Color gradient: transparent → blue → cyan → green → yellow → red ----

function heatColor(t: number): [number, number, number, number] {
	if (t < 0.01) return [0, 0, 0, 0];
	let r = 0;
	let g = 0;
	let b = 0;
	if (t < 0.25) {
		r = 0;
		g = Math.round(t * 4 * 255);
		b = 255;
	} else if (t < 0.5) {
		r = 0;
		g = 255;
		b = Math.round((0.5 - t) * 4 * 255);
	} else if (t < 0.75) {
		r = Math.round((t - 0.5) * 4 * 255);
		g = 255;
		b = 0;
	} else {
		r = 255;
		g = Math.round((1 - t) * 4 * 255);
		b = 0;
	}
	const alpha = Math.round(Math.min(t * 2.5, 1) * 210);
	return [r, g, b, alpha];
}

function worldToPixel(wx: number, wy: number): { px: number; py: number } {
	const { worldMinX, worldMaxX, worldMinY, worldMaxY } = config.heatmap;
	const px = ((wx - worldMinX) / (worldMaxX - worldMinX)) * OUTPUT_SIZE;
	const py = (1 - (wy - worldMinY) / (worldMaxY - worldMinY)) * OUTPUT_SIZE;
	return { px, py };
}

function buildHeatLayer(positions: { x: number; y: number }[]): Canvas {
	const heat = createCanvas(OUTPUT_SIZE, OUTPUT_SIZE);
	const ctx = heat.getContext("2d");
	ctx.globalCompositeOperation = "lighter";

	for (const pos of positions) {
		const { px, py } = worldToPixel(pos.x, pos.y);
		if (px < 0 || px > OUTPUT_SIZE || py < 0 || py > OUTPUT_SIZE) continue;

		const grad = ctx.createRadialGradient(px, py, 0, px, py, BLOB_RADIUS);
		grad.addColorStop(0, "rgba(255,255,255,0.25)");
		grad.addColorStop(1, "rgba(0,0,0,0)");
		ctx.fillStyle = grad;
		ctx.beginPath();
		ctx.arc(px, py, BLOB_RADIUS, 0, Math.PI * 2);
		ctx.fill();
	}

	const imageData = ctx.getImageData(0, 0, OUTPUT_SIZE, OUTPUT_SIZE);
	const data = imageData.data;
	for (let i = 0; i < data.length; i += 4) {
		const intensity = Math.min(data[i] / 255, 1);
		const [r, g, b, a] = heatColor(intensity);
		data[i] = r;
		data[i + 1] = g;
		data[i + 2] = b;
		data[i + 3] = a;
	}
	ctx.putImageData(imageData, 0, 0);

	return heat;
}

export async function generateHeatmap(): Promise<Buffer> {
	const cutoff = new Date(Date.now() - config.heatmap.retentionHours * 60 * 60 * 1000);
	const rows = await db
		.select({ x: heatmapPositions.x, y: heatmapPositions.y })
		.from(heatmapPositions)
		.where(sql`${heatmapPositions.loggedAt} >= ${cutoff}`);

	const canvas = createCanvas(OUTPUT_SIZE, OUTPUT_SIZE);
	const ctx = canvas.getContext("2d");

	const mapPath = config.heatmap.mapImagePath;
	if (mapPath && fs.existsSync(mapPath)) {
		const mapImg = await loadImage(mapPath);
		ctx.drawImage(mapImg, 0, 0, OUTPUT_SIZE, OUTPUT_SIZE);
	} else {
		const bg = ctx.createLinearGradient(0, 0, 0, OUTPUT_SIZE);
		bg.addColorStop(0, "#1a1a2e");
		bg.addColorStop(1, "#16213e");
		ctx.fillStyle = bg;
		ctx.fillRect(0, 0, OUTPUT_SIZE, OUTPUT_SIZE);

		if (!mapPath) {
			ctx.fillStyle = "rgba(255,255,255,0.15)";
			ctx.font = "14px sans-serif";
			ctx.fillText("Set HEATMAP_MAP_PATH to overlay on map", 20, OUTPUT_SIZE - 20);
		}
	}

	if (rows.length > 0) {
		const heatLayer = buildHeatLayer(rows);
		ctx.globalAlpha = 0.75;
		ctx.drawImage(heatLayer, 0, 0);
		ctx.globalAlpha = 1;
	}

	const now = new Date().toUTCString();
	ctx.fillStyle = "rgba(0,0,0,0.55)";
	ctx.fillRect(0, OUTPUT_SIZE - 28, OUTPUT_SIZE, 28);
	ctx.fillStyle = "#ffffff";
	ctx.font = "13px sans-serif";
	ctx.fillText(
		`${rows.length} sample(s) • last ${config.heatmap.retentionHours}h • updated ${now}`,
		8,
		OUTPUT_SIZE - 9,
	);

	return canvas.toBuffer("image/png");
}
