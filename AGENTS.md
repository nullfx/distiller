# AGENTS.md: working on Distiller

This file is for AI coding agents and the people who direct them. It explains what Distiller is, how the code is organised, how to build and test it, and the rules every change must follow. Human contributors should read it too; `README.md` covers using the app.

The maintainer keeps local, untracked documents in `docs/` (the design notes, and `docs/HANDOFF.md` with session notes: what was built recently, what's being verified on real hardware, open decisions). If `docs/HANDOFF.md` exists, read it at the start of a session and update it at the end. **Never commit anything in `docs/`** (it's in `.gitignore`), and never copy its private details (people's hardware, file paths on their drives, account or certificate names) into tracked files.

## What Distiller is

Distiller is a native SwiftUI app and a command-line tool for installing and running Windows games on Apple silicon Macs with Wine. It's driven by **recipes**: declarative, shareable YAML that says which Wine build and graphics translation layer a game needs, which winetricks verbs, registry settings, DLL overrides and environment variables, and how to adjust them for different Macs (**hardware overlays**). Players create recipes in the app, prove them with a **community check**, and share them through the companion repository **distiller-recipes**, whose published catalogue the app (Community tab) and the website read.

This file is the shared reference for the architecture and the rules; the recipe format is defined by the schemas in the recipes repository.

## Repository layout

| Path | Contents |
| --- | --- |
| `Sources/DistillerCore` | The engine: hardware probe, components (Wine builds, graphics layers), recipes, bottles (Wine prefixes), Wine processes, authoring, storage, the troubleshooting assistant's tools. No UI. |
| `Sources/DistillerCommunity` | The community catalogue client, GitHub sign-in (device flow) and recipe submission. |
| `Sources/distiller-cli` | The `distiller` command: everything the app does, from a terminal. |
| `Sources/DistillerApp` | The SwiftUI app. Keep it thin: it calls `DistillerEngine` and `DistillerCommunity`. |
| `Tests/DistillerCoreTests` | XCTest unit tests and fixtures. |
| `Scripts/` | `bundle-app.sh` (builds and signs `dist/Distiller.app`), `make-dmg.sh`, `notarize.sh` and `staple.sh` (release packaging, used by `.github/workflows/release.yml`; see `RELEASING.md`), `make-icon.sh` and `render-svg.swift` (the app icon). |
| `Design/` | The app icon source (`AppIcon.svg`), the generated `.icns`, and mockups. |
| `site/` | The website, published to GitHub Pages by `.github/workflows/pages.yml`: plain HTML, CSS and JavaScript modules, no build step. It reads the catalogue from distiller-recipes' Pages at run time. |
| `docs/` | The maintainer's local notes. Not in git. |

## Commands

- Build: `swift build`
- Test: `swift test` (about a minute; the disk-image importer tests make real disk images with `hdiutil`).
- CLI: `swift run distiller <command>`; `swift run distiller --help` lists them (hardware, setup, components, bottles, run, recipe …, install, games, launch, community, github, storage, mcp, assistant).
- App without bundling: `swift run DistillerApp`. As a bundle: `Scripts/bundle-app.sh [debug|release]` builds `dist/Distiller.app` with its icon.
- Website: `node --test site/tests/*.test.mjs` tests its data module; preview with `python3 -m http.server --directory site` (it fetches the live catalogue).
- Isolate experiments: `export DISTILLER_HOME=/tmp/distiller-dev` gives the engine its own support folder and `settings.json`, so experiments never touch a real library or real bottles.
- App icon: edit `Design/AppIcon.svg`, then run `Scripts/make-icon.sh`.
- Releases: pushing a `v*` tag runs `.github/workflows/release.yml` (Developer ID signing, notarization, a disk image, a GitHub Release) after the owner approves it. `RELEASING.md` explains the setup.

Shells that run under Rosetta (an x86_64 shell, for example one started from an Intel-only Homebrew bash) can't load the arm64 test bundle ("doesn't contain a version for the current architecture"). Run `arch -arm64 swift test` there; `uname -m` shows `x86_64` in an affected shell.

`Scripts/bundle-app.sh` signs with `DISTILLER_SIGN_IDENTITY` if set, otherwise the first "Apple Development" identity in the keychain, and ad hoc only as a last resort. macOS ties privacy permissions (Screen Recording, used for community-check screenshots) to the signature, and an ad-hoc signature changes with every build, so a permission granted to one build doesn't carry over to the next.

## How to work

- **Pull requests only.** `main` is protected: every change arrives as a pull request from a branch, reviewed and approved by a code owner, with the test workflow passing. Never push to `main`, force-push, or rewrite published history. Name branches by what they do (`fix/…`, `feature/…`, `docs/…`).
- **Keep the tests green and add tests with every change.** New behaviour gets tests; bug fixes get a test that fails without the fix. Network code is tested against in-process fakes (for example `FakeGitHub`, a route-based `URLProtocol` in `SubmitterTests.swift`), never against live services.
- **Small, focused changes.** One concern per pull request. Explain what changed and why, and how you verified it (tests, and on real hardware if it touches Wine, graphics layers or the file system).
- **Ask before changing direction.** Design decisions (the recipe format, the security model, what is shared publicly, licensing, the submission flow) belong to the maintainers. Propose options with trade-offs; don't silently pick one.
- **Don't run destructive or outward-facing actions on someone's machine or accounts without their explicit go-ahead**: deleting bottles or games, moving storage, signing in, pushing, opening or merging pull requests, publishing.
- **Don't quit or relaunch the app while a community check might be running** (`pgrep -lf wine` shows Wine processes). Quitting mid-check skips its cleanup and leaves a large test bottle behind (the app offers to remove such leftovers at its next launch).
- **Update the docs you affect**: `README.md` for user-visible behaviour, this file for new rules or architecture, and the local `docs/HANDOFF.md` (if present) for what you did.

## Architecture

- **One entry point.** `DistillerEngine` is the only API the app and the CLI use; both stay thin, so anything the app does can be exercised from a terminal and from tests.
- **Components.** Wine builds and graphics layers are versioned components with a `component.json` manifest, downloaded from their publishers' releases and checked against the release's SHA-256 digest, or imported from a folder or archive the player chose. `EnvironmentSetup` checks for and installs Rosetta, Wine, winetricks, cabextract and the open-source graphics layers; host commands come only from its fixed list, never from recipes.
- **Graphics layers.** D3DMetal (imported from the player's own Game Porting Toolkit download), DXMT and DXVK for macOS ("builtin" archives rearranged to `lib/wine/<arch>`) are merged into a clone of a Wine build by `StackComposer` (`placement: wine_lib`); prefix-DLL layers are copied into the bottle by `GraphicsPlacer`. WineD3D needs nothing extra.
- **Wine capabilities.** D3DMetal and DXMT need a Wine build whose `winemac.so` exports the macOS driver's `macdrv_*` functions; many upstream builds hide them. `WineCapabilities` (`Support/MachOExports.swift`, a bounds-checked Mach-O export-trie reader) detects this, `availableGraphics()` and `selectStack` respect it, and a recipe must never launch into a layer its Wine can't run.
- **Bottles.** A bottle is a Wine prefix for one game, an APFS clone of a per-Wine-build template prefix (`BottleStore.ensureTemplate`), so per-game isolation costs almost no space. A bottle keeps to the Wine that made it: `chooseWine(for:bottle:)` allows only the same build or family at the same or a newer version (Wine upgrades a prefix in place but can't go back). Anything that runs in an existing bottle must pass the bottle (`selectStack(for: game, recordUpgrade:)`).
- **Resolution order.** Built-in defaults → component manifest (`WineEnvironment`) → recipe → matching hardware overlays in file order → the player's local overrides.
- **Storage.** The support folder always holds `library.json`, `Logs/`, `RecipeCache/`, `Icons/`, `CommunityMedia/` and `settings.json`. Players can put Wine builds and bottles (bottles and templates together, because clones only work within a volume) on other drives. Locations must be APFS or Mac OS Extended and case-insensitive. A location on a disconnected drive is reported (`DistillerPaths.unavailable`) and never created in its place. After `moveStorage`, make a new engine.
- **Games used in place.** A `user_folder` step can link a folder on another drive into the bottle (`C:\Games\<Title>` → the original) and map that volume to the next free drive letter from D: (`DriveMapper`), so the game reads and writes its original files. Never copy such a game silently.
- **Library state.** `availability(of:)` reports ready / needs setup / unavailable with a reason; `launch` refuses with the same reason. Use `URL.followingSymlinks`, not `resolvingSymlinksInPath()`, which stops at a link whose target is missing.
- **Icons.** `PEIcon` reads a program's first icon group (through `PEImage`, the shared bounds-checked PE parser) and saves the largest image as PNG; a player-chosen icon wins. Icons stay out of recipes.
- **Authoring.** `RecipeDraft` turns builder choices into a `Recipe`; `GameInspector`/`PEFile` read a game's DLL imports to suggest settings; `ProgramFinder` ranks candidate programs; `TuningOptions` is the curated "Performance & display" list (each option is a recipe environment variable, documented for the version Distiller installs, with a link to that documentation).
- **Community check** (`Authoring/CommunityCheck.swift`, `DistillerEngine+CommunityCheck.swift`). Proves a recipe works for other players before it's shared: a fresh bottle, the publisher's official installer (its SHA-256 recorded), the recipe's settings, the installer run, the game launched, and the player confirming it reached its login or menu. While the game runs, the app's capture panel and a global hotkey capture screenshots; images the game saves itself are collected too; the program's icon is read. Check bottles are named `<title> (community check)` and hold a `community-check.pid` file so interrupted checks can be found (`orphanedCommunityCheckBottles`).
- **Pictures.** `CommunityMedia` normalises icons (square PNG, at most 256 px) and screenshots (JPEG, at most 1600 px wide and 600 KB, no metadata). A recipe shares up to three screenshots (the first is the cover) and the game's icon.
- **Community catalogue.** `CommunityRepository.default` points at the published catalogue (`index.json`, per-game detail files, `media/`). `CommunityMatch` compares the player's games with it (new game, new recipe, changed, in review, published).
- **Submission** (`DistillerCommunity/GitHub`, `Submission`). GitHub device-flow sign-in with the `public_repo` scope; the token lives in the keychain. `RecipeSubmitter` commits the recipe, an optional report, the game's catalogue file (first recipe only) and pictures to a new branch, then opens a pull request: on the contributor's fork, or on the repository itself for maintainers.
- **Links from the website** (`DistillerCommunity/DistillerLink.swift`, `AppModel+Links.swift`): `distiller://install?game=<slug>&recipe=<id>` and `distiller://game/<slug>`, registered in the bundle's Info.plist by `Scripts/bundle-app.sh`. A link only names a catalogue game and recipe; the app looks both up in the catalogue itself (downloading it again if needed) and shows a confirmation sheet. **Never act on a link without the player's confirmation, never accept anything but validated slugs, and never add link actions that take paths, URLs, commands or recipe content.**
- **Troubleshooting assistant.** `AssistantTools` are read-only tools (list games, read launch logs, read files in a game's folder or bottle, inspect a program, describe the environment), confined to the game's own folders, text only, size-capped, with the home folder shown as `~`. `MCPServer` serves them over stdio (JSON-RPC 2.0, one message per line) as `distiller mcp`, for MCP-capable assistants. The assistant is off until the player turns it on (`settings.json` `assistant_enabled`, absent means off); the server re-reads the switch on every request. Distiller never edits other apps' settings: the player adds `distiller mcp` to their AI app, which starts it. `MCPClientSetup` holds the connection steps and snippets (Claude Desktop, Claude Code, ChatGPT, LM Studio, Ollama, other stdio clients) shown by the app's connection guide (`AssistantConnectView`, opened from Settings ▸ AI Assistant) and `distiller assistant setup`; keep the website's docs (`site/docs/index.html#assistant`) in step with it.

## Rules that must hold

### Licensing and clean-room development

- **Distiller is MIT-licensed and clean-room.** Never copy, translate, port or paraphrase code (or tests, UI strings, or file formats' implementation details) from projects under copyleft licences (GPL, AGPL) or from proprietary software. That includes the projects that inspired Distiller: an archived GPL-3.0 macOS app that wrapped a commercial Wine fork with Apple's graphics layer, a GPL-3.0 Linux game manager whose shareable install scripts inspired recipes, and commercial Wine distributions. Learning from their public documentation and observable behaviour is fine; reproducing their code is not. Don't paste their source into a prompt or a tool to transform it.
- **Name things by function, not by product.** In code, docs and UI, describe other software by what it does and its licence (for example "a Wine build that exports the macOS driver functions"), except where a name is a technical necessity: a download source, a component Distiller installs, or an identifier in a published data format.
- **Dependencies must be MIT-compatible** (MIT, BSD, Apache-2.0, zlib and the like). No vendored copyleft code. Wine (LGPL-2.1) and copyleft graphics layers are only downloaded as separate components at the player's request and run as separate processes or libraries inside Wine; they're never linked into or shipped with Distiller.
- **Record the origin and licence** of anything not written for this project (assets, icons, snippets from permissively licensed sources) in a comment next to it.

### Apple software

- **Never bundle, download, upload, mirror or redistribute D3DMetal** or any other part of Apple's Game Porting Toolkit evaluation environment, and never download third-party builds that include it. Players import it from their own download from Apple (`GPTKImporter`). Tests use placeholder files shaped like the real disk image, never Apple's.

### Recipes are data

- **No recipe can run a host command.** Install steps are a fixed set of verbs (download with SHA-256, copy, registry, winetricks from an allowlist, DLL overrides, running a Windows program inside Wine, asking the player for a file or folder). Every path in a recipe goes through `BottlePath.resolve` and must stay inside the bottle. Environment keys go through `RecipePolicy.isAllowedEnvKey` (Wine and graphics-layer tuning only, excluding anything that redirects Wine or loads host code).
- **Keep the safety lists in sync** between `RecipePolicy.swift` and the recipes repository's `schema/recipe.schema.json`: winetricks verbs, environment prefixes and denials, DLL override values, and the `user_folder` rule that matches `BottlePath.isInsideDriveC`.
- **YAML must read the same in Python.** The recipes repository validates with PyYAML. Yams writes some doubles in a form PyYAML reads as text (`6e+1`); write whole numbers as `Int` in files the repository validates.

### Sharing with the community

- **Shared recipes install from the publisher's official installer** (`game.installer.url`, HTTPS, never a mirror or re-hosted copy) and download nothing else of the game. Players may use their own copy locally (`user_folder`, `user_file`); those steps are swapped for the official installer when shared.
- **Only checked recipes are submitted.** A recipe is submitted only after the community check passed for its current content, and only the checked recipe (`CommunityCheck.recipeToSubmit`) is ever sent.
- **Submissions are pull requests on a new branch; nothing is ever pushed to the base branch.** Contributors' branches go in their fork; maintainers (GitHub reports push, maintain or admin permission) branch in the community repository itself. Never ask for more than the `public_repo` scope. A published recipe may be revised (an `-update` branch) only by a maintainer or one of the authors listed in the *published* file, never the player's own copy.
- **Keep formats in sync** with the recipes repository: `CommunityIndex.swift` with `scripts/build_index.py` (index schema, per-game fields, `HardwareProfile.hardwareKey`), `GameDetails` with `schema/game.schema.json`, and the picture limits and paths in `CommunityMedia.swift` with `build_index.py` (`media/<slug>/icon.png`, `media/<slug>/<recipe-id>/<1-3>.jpg`). The test fixture `Tests/DistillerCoreTests/Fixtures/index.json` is generated by that script: `python3 scripts/build_index.py --include-examples --out <tmp>/index.json`, then copy it in.
- **Pictures belong to the game's publisher.** Icons and screenshots are shared only to identify the game, are excluded from the MIT licence, and come from the player's own test run. Never add game files, art or screenshots of real games to this repository; tests use generated placeholders.

### Safety, privacy and honesty

- **Wine is not a sandbox.** Windows programs run with the player's permissions. Never describe Wine or a bottle as isolation or protection in UI text or docs.
- **No telemetry, analytics or crash upload** without an explicit, off-by-default opt-in. Compatibility reports are sent only when the player submits one, and contain only what the report form shows.
- **Release signing stays in the `release` environment.** The Developer ID certificate and the notary API key exist only as that environment's secrets, which need the owner's approval and accept only `main` and `v*` tags. Never add a `pull_request`, `pull_request_target` or other untrusted trigger to a workflow that uses them, never echo or upload them, and keep the temporary keychain's cleanup step running `if: always()`.
- **Secrets never enter the repository**: no tokens, passwords, private keys, signing certificates, provisioning profiles or API keys, not even in tests (use obvious fakes like `gho_test`). The GitHub OAuth client ID is public by design and may be committed; there is no client secret.
- **The MCP server's standard output carries protocol messages only.** Never `print` in code the server reaches; log to standard error.
- **Assistant tools stay read-only and confined** to the game's own folders, text only, size-capped, with the home folder shown as `~`. The assistant stays off by default, the server only speaks stdio (never make it listen on a network port), and Distiller doesn't write AI apps' configuration files.
- **Respect the player's machine.** Never write outside the support folder, the chosen storage locations and the player's bottles; never create folders on a disconnected drive; ask before deleting anything that isn't disposable (bottles, games, rescued screenshots).

### The website

- Catalogue data is written by the community: put it on the page only as text (`el()` in `site/assets/site.js` sets `textContent`), never as HTML. Follow only `https:` links and pictures under the catalogue's `media/` (the checks in `catalogue-data.js`), and build `distiller://` links only from validated slugs.
- No trackers, analytics, cookies or third-party scripts and fonts. Keep it static: no build step, no framework.
- Keep `catalogue-data.js` in step with the index format (`CommunityIndex.swift`, `build_index.py`), with tests in `site/tests/`.

### User interface

- Standard SwiftUI and AppKit controls and system styles, minimum macOS 14. No custom "glass" effects.
- Plain, specific language in UI text: say what happened and what the player can do. Name drives, files and games rather than "an error occurred".
- Long work shows progress in the status bar (`AppModel.perform`), and failures become an alert with the reason.

## The companion repository

`distiller-recipes` holds the recipe, game and report schemas, the recipes, reports, game catalogue files and pictures, and the scripts and workflows that validate them and publish the catalogue to GitHub Pages. Changes there follow the same rules: pull requests only, owner approval, and its Validate and Contribution scope checks. Its `README.md` and `CONTRIBUTING.md` explain the format and the rules for contributors.
