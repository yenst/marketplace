# Changelog

## 0.1.2-beta (unreleased)

- Pattern tooltips (bags, vendors, auction house, links) show who in your guild knows the recipe and who has the skill to learn it.

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
