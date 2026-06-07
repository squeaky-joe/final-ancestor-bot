import fs from "fs";
import path from "path";
import { v4 as uuidv4 } from "uuid";
import { config } from "../config.js";
import type { IpcCommand, IpcResult } from "./types.js";

type PendingCallback = (result: IpcResult) => void;

export class IpcClient {
	private pending = new Map<string, PendingCallback>();
	private resultsOffset = 0;
	private pollTimer: ReturnType<typeof setInterval> | null = null;

	start(): void {
		const commandsFile = config.ipc.commandsFile();
		const resultsFile = config.ipc.resultsFile();
		console.log(`[ipc] commands file : ${commandsFile}`);
		console.log(`[ipc] results  file : ${resultsFile}`);

		ensureDir(path.dirname(commandsFile));

		this.resultsOffset = this.currentResultsSize();
		console.log(`[ipc] results offset at start: ${this.resultsOffset} bytes`);

		this.pollTimer = setInterval(() => this.poll(), config.ipc.pollIntervalMs);
		console.log(`[ipc] polling every ${config.ipc.pollIntervalMs}ms`);
	}

	stop(): void {
		if (this.pollTimer) clearInterval(this.pollTimer);
	}

	private currentResultsSize(): number {
		try {
			return fs.statSync(config.ipc.resultsFile()).size;
		} catch {
			return 0;
		}
	}

	private poll(): void {
		if (this.pending.size === 0) return;
		try {
			const resultsFile = config.ipc.resultsFile();
			const fd = fs.openSync(resultsFile, "r");
			const stat = fs.fstatSync(fd);
			if (stat.size <= this.resultsOffset) {
				fs.closeSync(fd);
				return;
			}
			const len = stat.size - this.resultsOffset;
			const buf = Buffer.allocUnsafe(len);
			fs.readSync(fd, buf, 0, len, this.resultsOffset);
			fs.closeSync(fd);
			this.resultsOffset = stat.size;

			for (const line of buf
				.toString("utf8")
				.split("\n")
				.filter((l) => l.trim())) {
				try {
					const result: IpcResult = JSON.parse(line);
					console.log(
						`[ipc] result: id=${result.id} verb=${result.verb} ok=${result.ok} source=${result.source ?? "bridge"}`,
					);
					const cb = this.pending.get(result.id);
					if (cb) {
						this.pending.delete(result.id);
						cb(result);
					}
				} catch (e) {
					console.warn(`[ipc] malformed result line: ${line} — ${e}`);
				}
			}
		} catch {
			// results file not yet created by the mod
		}
	}

	send(
		verb: string,
		steam: string,
		args: Record<string, unknown> = {},
	): Promise<IpcResult> {
		return new Promise((resolve, reject) => {
			const id = uuidv4();
			const cmd: IpcCommand = {
				id,
				ts: Math.floor(Date.now() / 1000),
				verb,
				steam,
				args,
			};

			const timeout = setTimeout(() => {
				this.pending.delete(id);
				reject(
					new Error(
						`Timed out after ${config.ipc.timeoutMs / 1000}s (verb=${verb}, steam=${steam}). ` +
							"Is the server online and are the mods loaded?",
					),
				);
			}, config.ipc.timeoutMs);

			this.pending.set(id, (result) => {
				clearTimeout(timeout);
				resolve(result);
			});

			this.writeCommand(cmd);
			console.log(`[ipc] sent: id=${id} verb=${verb} steam=${steam}`);
		});
	}

	sendAndAwaitSubMod(
		verb: string,
		steam: string,
		args: Record<string, unknown> = {},
	): Promise<IpcResult> {
		return new Promise((resolve, reject) => {
			const id = uuidv4();
			const cmd: IpcCommand = {
				id,
				ts: Math.floor(Date.now() / 1000),
				verb,
				steam,
				args,
			};

			const timeout = setTimeout(() => {
				this.pending.delete(id);
				reject(
					new Error(
						`Timed out after ${config.ipc.timeoutMs / 1000}s waiting for sub-mod response ` +
							`(verb=${verb}, steam=${steam}). Is the server online and are the mods loaded?`,
					),
				);
			}, config.ipc.timeoutMs);

			let ackReceived = false;

			const handler = (result: IpcResult) => {
				if (!result.source && !ackReceived) {
					ackReceived = true;
					if (!result.ok) {
						clearTimeout(timeout);
						resolve(result);
						return;
					}
					this.pending.set(id, handler);
					return;
				}
				clearTimeout(timeout);
				resolve(result);
			};

			this.pending.set(id, handler);
			this.writeCommand(cmd);
			console.log(`[ipc] sent (sub-mod): id=${id} verb=${verb} steam=${steam}`);
		});
	}

	private writeCommand(cmd: IpcCommand): void {
		const line = JSON.stringify(cmd) + "\n";
		const file = config.ipc.commandsFile();
		ensureDir(path.dirname(file));
		try {
			fs.appendFileSync(file, line, "utf8");
		} catch (e) {
			console.error(`[ipc] failed to write command to ${file}: ${e}`);
			throw e;
		}
	}
}

function ensureDir(dir: string): void {
	if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
}
