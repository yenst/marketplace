# AGENTS.md

Marketplace is a World of Warcraft (Forever) Lua 5.1 addon for browsing guild professions and recipes.

## Commands

Run from the repository root:

- Unit tests (pure Lua, no UI): `lua5.1 tests/run.lua`
- Smoke tests (mocked WoW API): `lua5.1 tests/smoke.lua`
- Package CurseForge zip (runs tests first): `tools/package.sh`
- Regenerate recipe catalog: `luajit tools/import-whatstraining.lua <path-to-WhatsTraining> > RecipeDB.lua`

## Architecture & Boundaries

- **Namespace & load order:** Every file receives `local ADDON, ns = ...` and loads in the order listed in `Marketplace.toc`. Keep everything `local` unless intentionally exposed on `ns` or required by WoW (`MarketplaceDB`, `SLASH_*`, `SlashCmdList`).
- **UI separation:** Keep `Init.lua`, `Scanner.lua`, `Sync.lua`, `Data.lua`, and `Auctionator.lua` free of WoW frame/UI dependencies so they stay testable under plain `lua5.1`.
- **Lua 5.1 target:** Do not use Lua 5.2+ features (`goto`, `//`, bitwise operators, `_ENV`).
- **Do not hand-edit:** `RecipeDB.lua` (generated from WhatsTraining) and `Libs/` (third-party embedded libraries).

## Readable & Writeable Code

- **Shallow nesting (max 3 levels):** Flatten conditionals with guard clauses and early `return`. Because Lua 5.1 has no `continue`, extract multi-condition loop bodies into small `local` helpers so they can exit early instead of stacking `if` blocks.
- **Small, single-purpose functions:** Aim for under ~40 lines per function. Split when a function mixes distinct concerns (e.g., querying data, transforming it, and updating UI) or cannot be understood in one glance.
- **Explicit over clever:** Prefer clear, linear control flow that is easy to change later. Avoid nested `a and b or c` expressions (and never use `a and b or c` when `b` can be `false` or `nil`). Name complex boolean conditions with a descriptive local variable or helper function.
- **No magic numbers or strings:** Lift layout dimensions, timeouts, protocol limits, and repeated keys into `UPPER_SNAKE_CASE` constants near the top of the file.
- **Consistent conventions:**
  - 4-space indentation.
  - `PascalCase` for public module functions (`Data.Crafters`, `ns.Refresh`).
  - `camelCase` for local helpers and variables (`initDB`, `itemName`).
  - `UPPER_SNAKE_CASE` for file-level constants (`MAX_LINE`, `ROW_HEIGHT`).
- **Predictable state:** Prefer returning new tables or values over silently mutating caller-owned arguments, unless mutation is the function's explicit purpose (e.g., `Scanner.Store`, `Sync.Chunk`).

## Comments & Documentation

- **Explain *why*, not *what*:** Never write comments that restate the code (e.g., `-- loop over recipes`, `-- return nil if missing`) or add conversational narration. Fix unclear logic by renaming or extracting a helper first.
- **Document what code cannot express:** Comment non-obvious invariants, WoW client/Forever quirks and API fallbacks (e.g., `ChatFrameUtil` vs. legacy globals, blank realm at login), protocol wire formats, and deliberate workarounds.
- **Document contracts and table shapes:**
  - Start each module with a brief comment summarizing its responsibility.
  - Above non-trivial public functions that take or return structured tables, document the expected fields and return shape concisely (matching `Data.Crafters` and `Data.Index`).
- **Section dividers:** In longer files, group related functions under a clean `-- Section Name ---` divider rather than commenting every individual helper.
- **No dead code:** Remove unused functions and commented-out code blocks; rely on Git history.

## Verification

- Always run `lua5.1 tests/run.lua` and `lua5.1 tests/smoke.lua` before finishing.
- Add or update unit tests in `tests/run.lua` for non-UI behavior and smoke assertions in `tests/smoke.lua` for UI, slash commands, or event flows.
