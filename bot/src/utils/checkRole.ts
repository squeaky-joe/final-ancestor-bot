import type { GuildMember, GuildMemberRoleManager } from "discord.js";

/**
 * Returns true if the member holds the given role, OR if no roleId is
 * configured (open to everyone with the command's Discord permission).
 */
export function hasRole(member: GuildMember, roleId: string | null | undefined): boolean {
	if (!roleId) return true;
	return (member.roles as GuildMemberRoleManager).cache.has(roleId);
}
