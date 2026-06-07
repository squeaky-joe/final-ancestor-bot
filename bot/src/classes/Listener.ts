import type { ClientEvents } from "discord.js";

export interface ListenerOptions<
	E extends keyof ClientEvents = keyof ClientEvents,
> {
	name: E;
	once?: boolean;
	execute: (...args: ClientEvents[E]) => Promise<void> | void;
}

export class Listener<E extends keyof ClientEvents = keyof ClientEvents> {
	public readonly name: E;
	public readonly once: boolean;
	public readonly execute: (...args: ClientEvents[E]) => Promise<void> | void;

	constructor(options: ListenerOptions<E>) {
		this.name = options.name;
		this.once = options.once ?? false;
		this.execute = options.execute;
	}
}
