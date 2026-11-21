# Marketplace

Find who can craft it. A profession browser for WoW Forever.

- **Guild:** everyone in your guild who runs Marketplace shares their recipes. Search across every profession or pick one, filter by member, and see who can craft a recipe, online first.
- **Public (planned):** list a profession publicly so players outside your guild can find you, with your fee and whether you provide the materials or they bring them.

Slash command: `/marketplace` (or `/mkt`).

## Status

Early setup. The browser window is a placeholder while the UI is designed.

## Development

- `tools/install.sh` links this repo into the WoW Forever install as `Interface/AddOns/Marketplace`, so edits show up after a `/reload`.
- `lua5.1 tests/run.lua` and `lua5.1 tests/smoke.lua` run the tests (luajit works too).
- Pushing a `v*` tag runs the release workflow (CurseForge + GitHub). It needs a `## X-Curse-Project-ID` line in the `.toc` and the `CF_API_KEY` secret first.
