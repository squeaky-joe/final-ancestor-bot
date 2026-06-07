export interface IpcCommand {
	id: string;
	ts: number;
	verb: string;
	steam: string;
	args: Record<string, unknown>;
}

export interface IpcResult {
	id: string;
	ts: number;
	verb: string;
	steam: string;
	ok: boolean;
	msg: string;
	source?: string; // present on sub-mod results (BodyDrop, DinoStorage, etc.)
	args?: string[];
}

export interface DinoListEntry {
	slot: string;
	classPath: string;
	growth: number;
	capturedAt: number;
}
