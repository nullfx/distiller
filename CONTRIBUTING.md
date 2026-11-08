# Contributing to Distiller

Thanks for helping. Distiller is a Mac app and command-line tool for running Windows games on Apple silicon with Wine, driven by shareable recipes. This guide covers contributing to the app, the command-line tool and the website. Recipes, and how games run on different hardware, live in the separate [distiller-recipes](https://github.com/nullfx/distiller-recipes) repository, which has its own guide. Everyone taking part follows the [Code of Conduct](CODE_OF_CONDUCT.md).

## Where things go

| You want to… | Go to |
| --- | --- |
| Share a recipe for a game, or report how a game ran | [distiller-recipes](https://github.com/nullfx/distiller-recipes). The app's **Submit to Community…** and **Report How It Ran…** do this for you. |
| Report a bug in the app, the `distiller` command or the website | [A bug report](https://github.com/nullfx/distiller/issues/new/choose) here |
| Suggest a feature | [A feature request](https://github.com/nullfx/distiller/issues/new/choose) here |
| Ask a question or get help with a game | [Discussions](https://github.com/nullfx/distiller/discussions) |
| Report a security problem | **Not** an issue. See [SECURITY.md](SECURITY.md). |
| Change code, docs or the website | A pull request, as below |

## Before you start

- **Read [AGENTS.md](AGENTS.md).** It's the project's reference for the architecture and the rules every change must follow, written for people and AI coding agents alike.
- **For anything bigger than a fix, open an issue first** and describe what you have in mind. Design decisions belong to the maintainers, including the recipe format, the security model, what's shared publicly, licensing and how submissions work. Agreeing on the approach first saves you rework.
- **Look for issues labelled** [`good first issue`](https://github.com/nullfx/distiller/labels/good%20first%20issue) or [`help wanted`](https://github.com/nullfx/distiller/labels/help%20wanted) if you're looking for somewhere to start.

## Setting up

You need an Apple silicon Mac with macOS 14 or later and Xcode 16 or later.

```sh
git clone https://github.com/<you>/distiller.git    # your fork
cd distiller
swift build
swift test                       # about a minute; run "arch -arm64 swift test" from a Rosetta shell
export DISTILLER_HOME=/tmp/distiller-dev    # keep experiments away from your real library
swift run distiller --help       # the command-line tool
Scripts/bundle-app.sh debug      # builds dist/Distiller.app
```

For the website: `node --test site/tests/*.test.mjs`, and preview with `python3 -m http.server --directory site`.

## Making a change

1. **Fork the repository and branch** from `main`. Name the branch by what it does: `fix/…`, `feature/…` or `docs/…`.
2. **Keep it focused.** Make one change per pull request.
3. **Add tests.** New behaviour gets tests, and a bug fix gets a test that fails without the fix. Network code is tested against in-process fakes, never live services. `swift test` and the website tests must pass.
4. **Update the docs you affect.** That's `README.md` for anything a player would notice, `AGENTS.md` for new rules or architecture, and the website's docs for how-tos.
5. **Open a pull request.** Fill in the template: what changed, why, and how you checked it. If your change touches Wine, graphics layers or the file system, say what you tried on a real Mac.

`main` is protected. Every pull request is reviewed and approved by a maintainer, and the **Test** workflow must pass before it can be merged. Please don't force-push a branch after review has started; add commits instead.

## Rules that matter most

The full list is in [AGENTS.md](AGENTS.md). The ones contributors most often run into:

- **Clean-room and MIT.** Distiller is MIT-licensed. Never copy, port or paraphrase code from copyleft (GPL, AGPL) or proprietary projects, including other Wine launchers. Learning from their documentation and behaviour is fine; reproducing their code isn't. Dependencies must have MIT-compatible licences. Note where anything you didn't write came from, and its licence, next to it.
- **Never include Apple's software.** D3DMetal and the rest of Apple's Game Porting Toolkit are never bundled, downloaded or redistributed. Players import them from their own download.
- **Recipes are data.** A recipe can never run a command on the player's Mac, and every path in a recipe stays inside the game's bottle. Changes to what recipes can do need a maintainer's agreement first.
- **No secrets, no telemetry.** Never commit tokens, keys or certificates, not even in tests. Nothing is sent anywhere without the player choosing to.
- **No game files or art.** Don't add games' files, art or screenshots to this repository; tests use generated placeholders.
- **Wine isn't a sandbox.** Never describe it as isolation or protection.

## AI-assisted contributions

You're welcome to use AI tools. `AGENTS.md` is written so coding agents can follow the project's rules, and `CLAUDE.md` points to it. You're responsible for what you submit: review it, make sure it builds and its tests pass, and make sure it follows the clean-room rule. Don't paste code from other projects into a prompt to have it rewritten.

## Licence

By contributing, you agree that your contributions are licensed under the project's [MIT License](LICENSE).
