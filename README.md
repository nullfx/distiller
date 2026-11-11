# Distiller

A native SwiftUI launcher for running Windows games on Apple silicon Macs with Wine, built around shareable, hardware-aware **recipes**.

**Website and game catalogue:** [nullfx.github.io/distiller](https://nullfx.github.io/distiller/). Its **Install in Distiller** buttons are `distiller://install?game=<slug>&recipe=<id>` links: Distiller looks the recipe up in the community catalogue and asks before installing anything.

> **Status: early development.** Games install and run from recipes on real Macs, recipes can be created in the app, proven with a community check and submitted to the community catalogue. Expect rough edges.

## Install

**[Download Distiller](https://github.com/nullfx/distiller/releases/latest/download/Distiller.dmg)** (the latest release, signed and notarized), open `Distiller.dmg` and drag Distiller to Applications. [All releases](https://github.com/nullfx/distiller/releases) have notes and checksums.

## Requirements

- An Apple silicon Mac with macOS 14 or later (macOS 27 recommended for Game Porting Toolkit 4).
- To build from source: Xcode 16 or later (it provides the Swift toolchain and macOS SDK, even when you edit in VS Code).
- Rosetta for x86_64 Wine builds, Wine, winetricks and cabextract. The app's **Setup Assistant** (or `distiller setup install --all`) installs these; see below.

## Build and test

```sh
swift build
swift test
swift run distiller hw            # prints this Mac's hardware fingerprint
swift run DistillerApp            # opens the app without bundling it
Scripts/bundle-app.sh           # builds dist/Distiller.app
```

Set `DISTILLER_HOME=/tmp/distiller-dev` while experimenting to keep test bottles out of `~/Library/Application Support/Distiller`.

## First-run setup

The app opens the **Setup Assistant** when something required is missing (it's also under **Distiller → Setup Assistant…** and in Components). It checks for, and installs:

| Item | How |
| --- | --- |
| Rosetta | `softwareupdate --install-rosetta`, after macOS asks for an administrator password. |
| Wine | The latest Wine Staging (or Devel) build from [Gcenx/macOS_Wine_builds](https://github.com/Gcenx/macOS_Wine_builds) releases, checked against GitHub's SHA-256 digest. |
| winetricks | The `winetricks` script from the latest [Winetricks](https://github.com/Winetricks/winetricks) release. |
| cabextract | `brew install cabextract`, if Homebrew is installed. |
| D3DMetal | Not downloadable for you: Apple's license requires you to download the Game Porting Toolkit yourself. The assistant links to Apple's download page and imports the disk image. |

From a terminal: `swift run distiller setup` shows the status and `swift run distiller setup install --all` installs what's missing.

### Keeping components up to date

**Settings ▸ Updates** sets how Distiller keeps Wine, DXVK, DXMT and winetricks current: **check, and ask before installing** (the default: it checks when the app starts and once a day, and Components shows **Update** next to anything new), **install updates automatically**, or **don't check**. **Check for Updates** in the Components toolbar works in every mode. An update installs next to the version it replaces and becomes the **active** version: new games use it, and games move to it the next time they start (a game's Wine only ever moves forward, because Wine updates a bottle in a way older builds can't read). **Make Active** on an older version (right-click it) keeps that component there; automatic updates then skip it. A game can also **stay on** a version instead of following updates: in the recipe workshop, **Bottle ▸ Versions** has a choice for its Wine build, graphics layer and winetricks (`distiller games versions <game>` from a terminal). Staying keeps a working game as it is, but it may miss fixes; Wine can only stay on the build the game uses now or a newer one. Before a game moves to a newer Wine, Distiller saves a **restore point** (a copy of its bottle, which takes almost no space at first) and updates the bottle, then asks after the first session whether the game works: **It Works** removes the copy, **Roll Back** puts it back and keeps the game on its old Wine (also in the workshop's Bottle tab, or `distiller games restore <game> --rollback`). **Settings ▸ Updates ▸ Keep restore points** sets how long copies stay: until you confirm the game works, up to 1, 7 (the default) or 30 days, or until you remove them. If a game won't work after moving to newer components, **Rebuild with Current Components…** (workshop ▸ Bottle) installs its recipe into a new bottle with the active versions, in the same window as a fresh install, reusing the files and folders you chose before where it can. The old bottle is kept until you decide: **Keep New Bottle** moves it to the Trash, **Switch Back** returns to it (`distiller games rebuild <game> [--keep|--switch-back]`). Anything the game keeps inside its bottle, such as saves under `C:\users`, isn't carried over. Versions no game needs are removed after an update, or with **Remove** in Components. D3DMetal and Wine builds you imported aren't checked or removed automatically, since they come from your own downloads.

Settings ▸ Updates also checks for a newer **Distiller**, from the GitHub releases of the repository your copy was built from (a fork's copies update from the fork). It's announced once (and **Distiller ▸ Check for Updates…** checks Distiller and the components on demand, always saying what it found), and installs only when you choose **Install and Relaunch**: Distiller downloads the disk image, checks it against the release's checksums and that it's signed by the same developer as your copy and notarized by Apple, moves your current copy to the Trash and reopens the new one. If it can't replace itself where it is, it opens the checked disk image for you to drag to Applications. `distiller app check` and `distiller app download` do the same from a terminal (without installing).

From a terminal: `distiller components check`, `distiller components update [<id>]`, `distiller components use <id>@<version>`, `distiller components clean` and `distiller components updates [ask|auto|off]`.

## Creating recipes

**Create Recipe…** in My Library (⌘N) walks through three starting points:

- **A game already on this Mac**: choose its folder and the program to launch. Distiller reads the program's imports to suggest a graphics layer, Windows version and winetricks. The recipe asks each player for their own copy of the folder (a `user_folder` step); you can copy the folder into the bottle (an instant APFS clone on the same drive) or use it where it is.
- **A Windows installer**: Distiller runs it in a new bottle, then you pick the program it installed.
- **An empty bottle**: set up the bottle yourself. Installers you run from Distiller are added to the recipe.

For installers whose file changes with every release (a game launcher's, such as Battle.net's), turn on **The installer changes with updates**: the community check then reads the installer's publisher signature, and the shared recipe checks that signature (for example `signer: "Blizzard Entertainment, Inc."`) instead of a fixed checksum (`distiller recipe check-signature` checks a file from a terminal).

The recipe's **official installer** link can be typed in, or found with **Get from Download Page…** in the workshop: browse to the publisher's download page in Distiller's private browser and click the Windows download, and Distiller records the page and the first of the download's links that works without the page (`distiller recipe check-link` tests links from a terminal). While a game installs, a window lists every step (the bottle, its settings, each component such as fonts, .NET Framework or the Visual C++ runtime, then the game's installer), checks them off as they finish and shows how long the current one has been running; some, such as .NET Framework, can take half an hour or more. **Cancel Install…** stops it and removes the new bottle. If none works on its own (some publishers' links need the page's cookies, or expire), choose **Use the Download Page**: the recipe keeps only the page, and each player downloads the installer there in Distiller's browser when they install it. Distiller checks the file is the same installer (by its checksum, or its publisher's signature) before using it. On the command line, `distiller install` asks for the path of the file you downloaded, or takes it with `--file installer=<path>`.

Every authored game opens in the **recipe workshop**: choose the program, adjust settings, edit the YAML directly or in your own editor (`recipe.yaml` in the bottle folder; choose **Reload from File** afterwards), run installers and Wine tools, and play to test. Changes to the Windows version, registry, graphics layer or winetricks are applied to the bottle when you save.

The CLI has the same steps: `distiller recipe inspect`, `recipe create`, `recipe programs`, `recipe set-launch`, `recipe edit`, `recipe reload` and `recipe run-installer`.

## Browsing community recipes

The **Community** tab lists the games in the [community catalogue](https://nullfx.github.io/distiller/games/). Search by title, publisher or description, filter by genre, graphics layer and rating, and sort by title, rating or most recently reported, as on the website. Click one to see its page before installing: screenshots from contributors' test runs, the game's details and links, and each recipe with its rating for Macs like yours, its settings, the recipe file and the reports behind its rating. **Install…** confirms what will be installed and from where.

## Submitting recipes

Shared recipes must install the game from its publisher's official installer. Before submitting, run the **community check**: in a fresh bottle Distiller downloads that installer, applies your recipe's settings and starts the installer. A floating panel follows the test bottle from then on. It works the same whether the installer finishes or starts a launcher or the game itself: choose the game's program from what's running (or start an installed one), capture a few screenshots (with the panel, or ⌃⌥⌘S from inside the game) and confirm it reached its login screen or menu.

**Submit to Community…** (in the workshop or a game's context menu) opens a window with a checklist of the steps (details, installer, community check, pictures, report, then review and submit), each marked done, needed or out of date; Submit is enabled once nothing is needed. It sends the checked recipe to [distiller-recipes](https://github.com/nullfx/distiller-recipes) as a pull request: you sign in to GitHub with a one-time code (the toolbar's GitHub button, or Settings), the app forks the repository to your account (maintainers get a branch in the repository itself), commits the recipe, the game's catalogue entry if it's new, your chosen screenshots and the game's icon, and optionally a report from your Mac, and opens the pull request. A maintainer reviews it; once merged it appears in the catalogue and the app's Community tab. Submitting again while the pull request is open updates it. Browsing and installing community recipes don't need an account.

From a terminal: `distiller github login`, `distiller recipe community-check <game-id>`, then `distiller recipe submit <game-id> --tier gold --confirm`. A fork of Distiller that uses its own catalogue sets `CommunityRepository.default` in `Sources/DistillerCommunity/CommunityClient.swift` (its repository and the client ID of a GitHub OAuth app with Device Flow enabled).

## Logs

Every launch writes a log to `~/Library/Application Support/Distiller/Logs`, which **Show Log** opens and the AI assistant reads. A log keeps its first 20 MB and last 4 MB however much a game prints. Distiller removes logs older than 14 days, then the oldest beyond 1 GB, when it starts and once a day; change both in **Settings ▸ Storage ▸ Logs**, or with `distiller logs set --keep-days 7 --limit-mb 500` (`distiller logs` shows the usage, `distiller logs clean` cleans up now).

## Troubleshooting with an AI assistant

Distiller includes an MCP server (`distiller mcp`) with read-only tools that let an AI assistant read a game's setup, launch logs, crash dumps and program details, and suggest recipe settings while you build a recipe. It's **off until you turn it on** in the **AI Assistant** tab of Settings (or `distiller assistant on`). Distiller doesn't change other apps' settings: you add its command (`/Applications/Distiller.app/Contents/Helpers/distiller mcp`) to your AI app's MCP servers, and the app starts the server when it needs it. Turning the assistant on opens the **Connect an AI Assistant** window, with the steps and copyable settings for Claude Desktop, Claude Code, ChatGPT, LM Studio, Ollama and other MCP clients; `distiller assistant setup [client]` prints the same in a terminal. Online assistants send what the tools return to their service; models in LM Studio or Ollama keep it on your Mac. The [docs](https://nullfx.github.io/distiller/docs/#assistant) walk through building a recipe from scratch with it.

## Quick Start: run Notepad

An easy quick start test is to run a Windows program from the CLI.

1. **Get a Wine build.** `swift run distiller setup install wine winetricks` downloads one. To use a build you downloaded yourself, import its folder or archive (an app bundle such as `Wine Staging.app` works; Distiller finds the `bin/wine` inside):

   ```sh
   swift run distiller components import "/path/to/wine" --kind wine --id winehq --family winehq --version 11.0
   ```

2. **Create a bottle and run Notepad.** The first bottle per Wine build takes a minute while Wine builds a template prefix; later bottles are APFS clones and take seconds.

   ```sh
   swift run distiller bottles create "Test"
   swift run distiller bottles                    # copy the bottle ID
   swift run distiller run <bottle-id> notepad
   ```

3. **Optional: D3DMetal.** Download the Game Porting Toolkit from developer.apple.com, then:

   ```sh
   swift run distiller components import-gptk ~/Downloads/<GPTK disk image>.dmg
   ```

4. **Optional: winetricks.** Download the `winetricks` script and import its folder with `--kind winetricks --arch universal`.

## Layout

| Path | Contents |
| --- | --- |
| `Sources/DistillerCore` | Engine: hardware probe, components, recipes, bottles, Wine process handling. No UI. |
| `Sources/DistillerCommunity` | Reads the community index, game detail files and recipes; builds report links. |
| `Sources/distiller-cli` | The `distiller` command. Everything the app does, from a terminal. |
| `Sources/DistillerApp` | SwiftUI app. |
| `Tests/DistillerCoreTests` | Unit tests. Fixtures come from the distiller-recipes repository. |
| `site/` | The website (GitHub Pages): plain HTML, CSS and JavaScript that read the published catalogue. `node --test site/tests/*.test.mjs` tests its data code. |
| `Scripts/bundle-app.sh` | Wraps the build into a signed `dist/Distiller.app` (your Apple Development identity, or `DISTILLER_SIGN_IDENTITY`). |

The companion repository [distiller-recipes](https://github.com/nullfx/distiller-recipes) holds the recipe, game and report schemas, the community's recipes, reports and pictures, and the scripts and GitHub workflows that validate them and publish the catalogue.

## Working in VS Code

Open this folder in VS Code and install the recommended Swift extension (`swiftlang.swift-vscode`). It builds, tests and debugs SwiftPM packages using the toolchain from your Xcode install.

## Releases

Signed, notarized disk images are published on the [Releases](https://github.com/nullfx/distiller/releases) page by GitHub Actions. Versions are major.minor.revision: `VERSION` holds the major and minor, and each release (run by hand from Actions ▸ Release, then approved) takes the next revision. Each release has `Distiller-<version>.dmg` and the same image as `Distiller.dmg`, so [github.com/nullfx/distiller/releases/latest/download/Distiller.dmg](https://github.com/nullfx/distiller/releases/latest/download/Distiller.dmg) always downloads the newest release. [RELEASING.md](RELEASING.md) explains how releases are signed and how to set up the signing secrets in a fork.

## Contributing

Changes arrive as pull requests; `main` is protected, a maintainer reviews every pull request, and the test workflow must pass. Start with [CONTRIBUTING.md](CONTRIBUTING.md); everyone follows the [Code of Conduct](CODE_OF_CONDUCT.md), and security problems are reported privately as described in [SECURITY.md](SECURITY.md). [AGENTS.md](AGENTS.md) explains the architecture and the rules every change follows (licensing, the recipe security model, what may be shared); it's written for AI coding agents and people alike (`CLAUDE.md` simply imports it).

## License

MIT. Distiller is a clean-room implementation: other game launchers, including GPL-licensed ones, informed its design, but no code was copied from them. Wine and the graphics layers are downloaded as separate components under their own licences. D3DMetal is never bundled; players import it from their own Game Porting Toolkit download.
