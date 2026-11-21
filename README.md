# Marketplace

Find who can craft it. A profession browser for WoW Forever.

- **Guild:** everyone in your guild who runs Marketplace shares their recipes. Search across every profession or pick one, filter by member, and see who can craft a recipe, online first.
- **Public:** players outside your guild find you through your public listings, with your fee and whether you provide the materials or they bring them. Listers who are online right now show as live.
- **My listings:** pick which professions and recipes to list, set a default fee and materials terms, and give single recipes their own terms.
- **Auctionator (optional):** reagent prices, what the mats cost, what you're short, and a shopping list for the missing reagents.

Slash command: `/marketplace` (or `/mkt`).

## Status

In development: guild browser, public listings and the listings editor work; testing in game.

Public listings travel over a hidden chat channel (`MarketplaceAddon`); nothing is downloaded until you open the Public tab.

## Development

- `tools/install.sh` links this repo into the WoW Forever install as `Interface/AddOns/Marketplace`, so edits show up after a `/reload`.
- `lua5.1 tests/run.lua` and `lua5.1 tests/smoke.lua` run the tests (luajit works too).
- Pushing a `v*` tag runs the release workflow (CurseForge + GitHub). It needs a `## X-Curse-Project-ID` line in the `.toc` and the `CF_API_KEY` secret first.
