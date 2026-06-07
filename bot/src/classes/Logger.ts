import chalk from "chalk";

export class Logger {
	private timestamp(): string {
		return new Date().toTimeString().slice(0, 8);
	}

	private fmt(level: string, color: (s: string) => string): string {
		return color(`[${this.timestamp()}] [${level}]`);
	}

	info(...args: unknown[]): void {
		console.log(this.fmt("INFO ", chalk.cyan), ...args);
	}

	success(...args: unknown[]): void {
		console.log(this.fmt("OK   ", chalk.green), ...args);
	}

	warn(...args: unknown[]): void {
		console.warn(this.fmt("WARN ", chalk.yellow), ...args);
	}

	error(...args: unknown[]): void {
		console.error(this.fmt("ERROR", chalk.red), ...args);
	}

	debug(...args: unknown[]): void {
		console.log(this.fmt("DEBUG", chalk.gray), ...args);
	}
}
