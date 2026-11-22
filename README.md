# Marketplace

Find who can craft it. A profession browser for WoW Forever.

- **Guild:** everyone in your guild who runs Marketplace shares their recipes. Search across every profession or pick one, filter by member, and see who can craft a recipe, online first. Recipes are passed on between guildmates, so you also see crafters who haven't been online at the same time as you.
- **Favorites:** right-click a recipe (or use the star in its details) to pin it at the top of the list.
- **Auctionator (optional):** reagent prices, what the mats cost, what you're short, and a shopping list for the missing reagents.

Slash command: `/marketplace` (or `/mkt`).

## Status

In development: the guild browser works; testing in game.

## Development

- `tools/install.sh` links this repo into the WoW Forever install as `Interface/AddOns/Marketplace`, so edits show up after a `/reload`.
- `lua5.1 tests/run.lua` and `lua5.1 tests/smoke.lua` run the tests (luajit works too).
- Pushing a `v*` tag runs the release workflow (CurseForge + GitHub). It needs a `## X-Curse-Project-ID` line in the `.toc` and the `CF_API_KEY` secret first.
