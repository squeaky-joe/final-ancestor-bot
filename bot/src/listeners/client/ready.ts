import { Listener } from "../../classes/index.js";
import { registerCommands } from "../../utils/index.js";
import { startHeatmapScheduler } from "../../heatmap/index.js";
import type { FinalAncestorClient } from "../../classes/Client.js";

export default new Listener({
	name: "clientReady",
	once: true,
	execute(client) {
		const c = client as unknown as FinalAncestorClient;
		c.logger.success(`Logged in as ${c.user?.tag}`);
		c.ipc.start();
		startHeatmapScheduler(c);
		void registerCommands([...c.commands.values()], c.logger);
	},
});
