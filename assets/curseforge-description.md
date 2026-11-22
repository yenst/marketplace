# Marketplace

**Find who in your guild can craft it.** A profession browser for WoW Forever, laid out like the in-game profession window.

> **Beta.** Guild sync is new: please report anything odd on GitHub (link below).

## What it does

- **Browse your guild's professions.** One tab per profession, or all of them at once. Recipes are grouped by category, and you can search by recipe, reagent or member.
- **See who can craft it.** Every recipe lists the guildmates who know it, online first, with a **Whisper** button that opens a tell with the recipe link already in it.
- **Every recipe in the game, not just your guild's.** Each profession also lists the patterns nobody in your guild has yet, under *Not in your guild*, sorted by required skill. A bar at the top shows how many patterns your guild has unlocked.
- **Where to learn it.** Each recipe shows the skill it needs and where it comes from:
  - trainer and cost
  - the zones its vendors are in (for your faction)
  - quests
  - drops
  - reputation and Merchant's Favor
- **Crafters don't need to be online.** Recipes are passed on from guildmate to guildmate, so you can find a crafter you've never been online at the same time as.
- **Favorites.** Right-click a recipe, or use the star, to pin it at the top.
- **Auctionator support (optional).** Reagent prices, what the mats cost, what you're still short of (bags and bank), what the item sells for, and a one-click Auctionator shopping list for the missing reagents.
- **Links and previews.**
  - Shift-click the crafted item, a reagent or the recipe pattern to link it in chat.
  - Ctrl-click to preview it in the dressing room.
- **Easy to reach.** A Marketplace tab on the Guild & Communities window, a minimap button, or `/mkt`.

## How it works

Open each of your profession windows once and Marketplace remembers what you can craft. Guildmates who also run Marketplace share their recipes automatically, over hidden addon messages on the guild channel. Only recipe IDs and skill levels are shared, nothing else. The more of your guild runs it, the more complete the list gets.

## Commands

- `/mkt` opens or closes the browser (`/marketplace` works too).
- `/mkt guild` lists the guildmates you have data for.
- `/mkt status` shows what Marketplace knows about this character.
- `/mkt minimap` shows or hides the minimap button.
- `/mkt debug` shows or hides sync activity in chat.

## Notes

- Made for **WoW Forever** only.
- Guildmates need Marketplace too for their recipes to show up.

## Credits

The recipe list and sources come from [WhatsTraining](https://www.curseforge.com/wow/addons/whatstraining)'s Forever data (MIT license). Thanks to its author!

## Feedback

Bugs and ideas: [github.com/yenst/marketplace/issues](https://github.com/yenst/marketplace/issues)
