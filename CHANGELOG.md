# Changelog

## 0.1.0 (unreleased)

- Guild browser laid out like the profession window: profession tabs, categories in game order, reagents, crafters online first, whisper with the recipe link.
- Guild sync over hidden addon messages.
- Recipes are relayed between guildmates: everyone keeps what they received and passes it on, so crafters don't need to be online to be found.
- Sync protocol 2: everything on the guild channel; login sends a one-line fingerprint and only differences are exchanged; recipes packed several times smaller; updates bundled (30s after a change, at most every 2 minutes); a check every 15 minutes repairs anything missed.
- Auctionator integration: reagent prices, mats cost, sell price, shopping lists.
- Money shown with gold, silver and copper coin icons.
- Favorite recipes, listed at the top.
- Marketplace tab on the Guild & Communities window, and a minimap button (`/mkt minimap`).
- Shift-click the crafted item, a reagent or the recipe pattern to link it; ctrl-click to preview it.
- Every recipe of every profession, including ones nobody in the guild has, with where to learn it (trainer, vendor zones, quests, drops, reputation). Data from WhatsTraining (MIT).
