# Security policy

## Reporting a vulnerability

**Please don't open a public issue for a security problem.** Report it privately through GitHub instead:

**[Report a vulnerability](https://github.com/nullfx/distiller/security/advisories/new)** (the repository's **Security** tab ▸ **Report a vulnerability**)

Only the maintainers see your report. Please include:

- what the problem is and what an attacker could do with it;
- how to reproduce it: the steps, a recipe file, a link, or a proof of concept;
- the Distiller version (**Distiller ▸ About Distiller**, or `distiller --version`) and your macOS version.

Distiller is maintained by volunteers, so responses are best effort. We aim to acknowledge a report within a week. We'll keep you posted while we investigate and fix it, agree on when to disclose it with you, and credit you in the advisory unless you'd rather not be named. Please give us a reasonable chance to release a fix before telling anyone else.

## Supported versions

Security fixes go into the **latest release** only. Download it from [Releases](https://github.com/nullfx/distiller/releases/latest) and keep up to date.

## What's in scope

Distiller makes security promises that its design depends on. A way to break any of them is a vulnerability:

- **Recipes can't run commands on your Mac.** A recipe, whether from the community catalogue, a file or a link, must never run a host command or program outside Wine, or load host code.
- **A recipe's paths stay inside its bottle.** No recipe step may read, write or link outside the game's own bottle, except folders the player explicitly chose.
- **Only allowed settings.** A recipe's environment variables must stay within the allowed Wine and graphics-layer settings, and its winetricks components within the allowlist.
- **Downloads are verified.** A download, including a file the player downloads from a publisher's page for a recipe, must not get past its SHA-256 checksum or, for installers that change with every update, its publisher's Authenticode signature (a code-signing certificate macOS trusts, from the signer the recipe names, over an unchanged file), and components must not be installed from anywhere other than their publishers' releases.
- **`distiller://` links can't act alone.** A website link must never install anything without the player's confirmation, or act on anything but a validated catalogue game and recipe.
- **The AI assistant only reads.** The MCP server's tools must not change files, run programs, or read outside a game's own folders. The server must not be reachable from the network, and must serve nothing while the assistant is turned off.
- **Your GitHub account is safe.** The sign-in token must stay in the keychain. Distiller must never ask for more than the `public_repo` scope or push anywhere but a new branch.
- **Releases are authentic.** A way to get unsigned or tampered code into a release or the disk image counts.
- **The website is safe.** Catalogue data must never be able to run script on the website or in the app.

## What's out of scope

- **Wine isn't a sandbox.** Windows programs, including the games you install, run with your user's permissions and can do anything you can. Install games you trust. Problems that only show that a Windows program can harm the Mac it runs on aren't Distiller vulnerabilities.
- **Bugs in Wine, DXVK, DXMT, MoltenVK, winetricks or Apple's Game Porting Toolkit** belong with those projects. Please report them to them, and tell us too if Distiller should protect against them.
- **The games themselves**, and recipes that simply don't work.
- Problems that need someone who already has administrator access to your Mac, or physical access to it.
