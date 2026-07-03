import type {
	ButtonInteraction,
	ModalSubmitInteraction,
	StringSelectMenuInteraction,
} from "discord.js";
import { handleLinkButton } from "./buttons/link.js";
import { handleStoragePark } from "./buttons/storagePark.js";
import { handleStorageRetrieve } from "./buttons/storageRetrieve.js";
import { handleStorageList } from "./buttons/storageList.js";
import { handleStorageSlay } from "./buttons/storageSlay.js";
import { handleStorageSlayConfirm } from "./buttons/storageSlayConfirm.js";
import { handleStorageRetrieveSlot } from "./selects/storageRetrieveSelect.js";
import { handleLinkModal } from "./modals/linkModal.js";

type ButtonHandler = (i: ButtonInteraction) => Promise<void>;
type ModalHandler = (i: ModalSubmitInteraction) => Promise<void>;
type SelectMenuHandler = (i: StringSelectMenuInteraction) => Promise<void>;

const BUTTON_HANDLERS = new Map<string, ButtonHandler>([
	["link_steam", handleLinkButton],
	["storage_park", handleStoragePark],
	["storage_retrieve", handleStorageRetrieve],
	["storage_list", handleStorageList],
	["storage_slay", handleStorageSlay],
	["storage_slay_confirm", handleStorageSlayConfirm],
]);

const MODAL_HANDLERS = new Map<string, ModalHandler>([
	["link_modal", handleLinkModal],
]);

const SELECT_HANDLERS = new Map<string, SelectMenuHandler>([
	["storage_retrieve_slot", handleStorageRetrieveSlot],
]);

export async function handleButton(
	interaction: ButtonInteraction,
): Promise<void> {
	const handler = BUTTON_HANDLERS.get(interaction.customId);
	if (handler) await handler(interaction);
}

export async function handleModal(
	interaction: ModalSubmitInteraction,
): Promise<void> {
	const handler = MODAL_HANDLERS.get(interaction.customId);
	if (handler) await handler(interaction);
}

export async function handleSelectMenu(
	interaction: StringSelectMenuInteraction,
): Promise<void> {
	const handler = SELECT_HANDLERS.get(interaction.customId);
	if (handler) await handler(interaction);
}
