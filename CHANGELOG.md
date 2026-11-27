# Changelog

## 0.1.11

- Sorting: added a Sort dropdown to the filter bar (Name, Skill low-to-high, Skill high-to-low, Online first, and Most crafters), remembered between sessions.
- Recipe list: added clickable `Recipe` and `Skill` column headers, moved required skill numbers into the right column (instead of repeating "Skill" or showing recipe counts on every category header), and placed the online green dot in front of recipe names at a consistent indent.

## 0.1.10

- Fixed characters sharing the same first name on WoW Forever inheriting and syncing each other's professions and skill levels: saved characters are now keyed by `UnitGUID("player")` instead of first name, with verified migration of pre-existing entries.
- Guild sync now clears stale copies of characters with no professions when reconciling bucket lists, and scans professions before sending the login hello.
- Avoided first-name collisions in `Data.Crafters` when own characters lack a full name or multiple guildmates share the same first name.

## 0.1.9

- Internal cleanup and refactoring across the browser window, recipe data model, scanner, sync decoder, and UI helpers for improved readability and maintainability (no functional changes).

## 0.1.8

- Window: remembers its position between sessions, adds scrollbars to the recipe list and member dropdown, adds a clear button to the search box, closes the member dropdown when clicking outside, and clears the details pane when no recipes match.
- Tooltips: offline crafters now appear grey as intended, forbidden tooltips are skipped safely, and `/mkt tooltips` toggles Marketplace tooltip lines on or off.
- Auctionator: crafted item and pattern prices now use auction house prices rather than vendor values, multi-output recipes account for craft yield, and missing reagents without a price are flagged.
- Sync & scanning: fixed random jitter on the 15-minute sync check, coalesced login presence replies, reset session state when switching guilds, disabled Refresh while on cooldown, sped up skill-level updates, handled dropping your last crafting profession, and kept recipe metadata session-only instead of saving it to disk.
- Fixes: verified whisper chat mode before inserting tell text, preserved your character's guild name at login, trimmed search whitespace, and initialized the minimap button and guild tab after loading the theme.

## 0.1.7

- The Track recipe checkbox sat on top of the "Mats cost" tile: it's now in the recipe header, under the favorite star.

## 0.1.6

- The whisper button opened a tell without the recipe link in it: fixed. It now starts the message with "Hi! Could you craft [recipe] for me?".

## 0.1.5

- Out of beta.
- Profession tabs no longer show a tooltip on mouseover.

## 0.1.4-beta

- Logging in while a guildmate was already online only passed on your own recipes, not the ones you hold of others: fixed. The guild roster is still filling in right after login, and guildmates missing from it were taken to have left the guild.

## 0.1.3-beta

- Item tooltips (bags, vendors, auction house, links) show who in your guild can craft the item: online crafters first in their class colour, offline ones grey, with their profession level.
- Refresh button at the bottom of the window: compares with the guild right away instead of waiting for the 15-minute check. Only recipes newer than the ones you have are fetched, and the line next to it says how it went ("Up to date", "Updated 3 guildmates", …).

## 0.1.2-beta

- Track recipe checkbox in the recipe details, like the profession window's: its reagents go to your objective tracker.
- Pattern tooltips (bags, vendors, auction house, links) show who in your guild knows the recipe, who has the skill to learn it, and who has the profession but needs more skill.

## 0.1.1-beta

- Profession level next to player names, e.g. "Billy Joel (215)"; levels sync with a one-line update as you skill up.
- Class icons next to player names.
- Icons instead of words where the game uses them: recipe sources (trainer, vendor, quest, drop…), the faction crest and the whisper button; online crafters no longer say "Online" under their name.
- Member filter: pick a guildmate from the dropdown next to the search (or click a crafter's name) to see only their patterns.
- Shift-clicking an item that hadn't loaded yet put "item:1234" in chat instead of the link: fixed.
- Your professions are shared at login and when you learn a recipe, without opening the profession windows first. (Opening a window still adds its category grouping.)

## 0.1.0-beta

- Guild browser laid out like the profession window: profession tabs, categories in game order, reagents, crafters online first, whisper with the recipe link.
- Guild sync over hidden addon messages.
- Recipes are relayed between guildmates: everyone keeps what they received and passes it on, so crafters don't need to be online to be found.
- Sync protocol 2: everything on the guild channel; login sends a one-line fingerprint and only differences are exchanged; recipes packed several times smaller; updates bundled (30s after a change, at most every 2 minutes); a check every 15 minutes repairs anything missed.
- Auctionator integration: reagent prices, mats cost, sell price, shopping lists.
- Money shown with gold, silver and copper coin icons.
- New icon: a faceted blue market stall with a gold sparkle.
- Favorite recipes, listed at the top.
- Marketplace tab on the Guild & Communities window, and a minimap button (`/mkt minimap`).
- Shift-click the crafted item, a reagent or the recipe pattern to link it; ctrl-click to preview it.
- Every recipe of every profession, including ones nobody in the guild has, with where to learn it (trainer, vendor zones, quests, drops, reputation). Data from WhatsTraining (MIT).
