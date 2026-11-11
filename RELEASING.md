# Releasing Distiller

Versions are **major.minor.revision** (`1.0.3`).

- **`VERSION`**, at the top of the repository, holds the major and minor version (`1.0.0`). You change it by hand, in a pull request, only to start a new major or minor version: `Scripts/bump-version.sh minor` (1.0.x → 1.1.0) or `major` (1.x → 2.0.0).
- **The revision** goes up by one with every release. It isn't written in a file. The release tags (`v1.0.0`, `v1.0.1`, …) record it, and `Scripts/next-version.sh` works out the next one: one past the newest `v<major>.<minor>.<n>` tag, or `VERSION`'s own revision (normally 0) for the first release of a new major.minor.

Local builds (`Scripts/bundle-app.sh`) use `VERSION` as it stands. Released builds carry their release version, which the app's About box, `distiller --version` and the MCP server report.

Releases are built by GitHub Actions (`.github/workflows/release.yml`) when you run the workflow by hand on `main` and approve it. The workflow does the following:

1. Works out the version (`Scripts/next-version.sh`) and builds `Distiller.app` for Apple silicon with it. The build number is the workflow's run number.
2. Signs the app and its `distiller` helper with a **Developer ID Application** certificate, using the hardened runtime and a secure timestamp.
3. Notarizes the app with Apple and staples the ticket to it.
4. Packs it in a disk image (`Distiller-1.0.3.dmg`) with an Applications shortcut, then signs, notarizes and staples the image too.
5. Tags the commit `v<version>`. This happens only after a successful build, so a rejected or failed run leaves no tag.
6. Publishes a GitHub Release with the disk image twice, as `Distiller-1.0.3.dmg` and as `Distiller.dmg`, plus `SHA256SUMS.txt`. The release notes start with install instructions, followed by notes generated from the merged pull requests.

The website and README link to `https://github.com/nullfx/distiller/releases/latest/download/Distiller.dmg`. GitHub redirects that address to `Distiller.dmg` in the newest release that isn't a pre-release, so the links never need updating. Keep the file name `Distiller.dmg`.

To do a **dry run**, open Actions ▸ Release ▸ Run workflow on `main`. It does the same build, but keeps the disk image as a workflow artifact for a week instead of publishing a release.

## How signing works

The workflow signs with a `.p12` copy of the Developer ID certificate. Apple's cloud-managed certificates can't be used here: Xcode's cloud signing works only through `xcodebuild -exportArchive`, and Apple doesn't support it for Developer ID when CI authenticates with an App Store Connect API key. The API key is still used, for notarization.

The certificate never enters the repository:

- It's stored as an **encrypted secret** of the `release` environment.
- Every run waits for the owner's approval.
- Runs only start from `main` or a `v*` tag, never from a pull request.
- During the job, the certificate lives in a temporary keychain with a random password, which is deleted when the job ends, even if it fails.

## One-time setup

You need an Apple Developer Program membership as the Account Holder or an Admin.

### 1. Developer ID Application certificate

If you don't have one, create it in Xcode (Settings ▸ Accounts ▸ Manage Certificates ▸ + ▸ Developer ID Application). You can also create it at [developer.apple.com ▸ Certificates](https://developer.apple.com/account/resources/certificates/list) from a certificate signing request.

Then export it with its private key:

1. In **Keychain Access**, select the login keychain and choose **My Certificates**.
2. Find "Developer ID Application: *your name* (*team ID*)". Expand it to check it has a private key.
3. Select the certificate and choose **File ▸ Export Items…**. Save it as `.p12` (Personal Information Exchange) with a strong password.
4. Base64-encode it for the secret:

   ```sh
   base64 -i DeveloperID.p12 | pbcopy
   ```

After adding the secret (step 4), delete the `.p12` file and keep the password in your password manager. If the certificate ever leaks, revoke it at developer.apple.com and make a new one. Apps you've already notarized keep working.

### 2. App Store Connect API key (for notarization)

1. Go to [App Store Connect ▸ Users and Access ▸ Integrations ▸ App Store Connect API](https://appstoreconnect.apple.com/access/integrations/api). Choose **Team Keys** and generate a key with the **Developer** role. Notarization needs nothing more.
2. Note the **Issuer ID** (above the list) and the key's **Key ID**.
3. Download the `.p8` file. Apple lets you download it only once. Base64-encode it:

   ```sh
   base64 -i AuthKey_XXXXXXXXXX.p8 | pbcopy
   ```

### 3. The `release` environment

In the repository, go to **Settings ▸ Environments ▸ New environment** and name it `release`:

- **Required reviewers:** add yourself. Every release run then waits for your approval.
- **Prevent self-review:** leave this off, so you can approve your own tags.
- **Deployment branches and tags:** choose *Selected branches and tags*, then add the branch `main` and the tag pattern `v*`.

### 4. Secrets and variable

Add these under the `release` environment (not as repository secrets):

| Name | Kind | Value |
| --- | --- | --- |
| `DEVELOPER_ID_P12_BASE64` | Secret | The base64 of the `.p12` |
| `DEVELOPER_ID_P12_PASSWORD` | Secret | Its password |
| `NOTARY_KEY_P8_BASE64` | Secret | The base64 of the `.p8` |
| `NOTARY_KEY_ID` | Secret | The API key's Key ID |
| `NOTARY_ISSUER_ID` | Secret | The Issuer ID |
| `APPLE_TEAM_ID` | Variable | Your 10-character team ID; the workflow refuses a certificate from another team |

With the GitHub CLI, from the repository folder:

```sh
gh secret set DEVELOPER_ID_P12_BASE64 --env release < <(base64 -i DeveloperID.p12)
gh secret set DEVELOPER_ID_P12_PASSWORD --env release
gh secret set NOTARY_KEY_P8_BASE64 --env release < <(base64 -i AuthKey_XXXXXXXXXX.p8)
gh secret set NOTARY_KEY_ID --env release
gh secret set NOTARY_ISSUER_ID --env release
gh variable set APPLE_TEAM_ID --env release --body XXXXXXXXXX
```

(Commands without input prompt for the value, so it stays out of your shell history.)

### 5. Protect release tags (recommended)

Under **Settings ▸ Rules ▸ Rulesets ▸ New tag ruleset**, target `v*` and restrict **updates** and **deletions**, with the repository admin role allowed to bypass. A published release's tag then can't be moved or removed.

Leave **creations** unrestricted: the release workflow creates the tag itself after you approve the run. A personal-account repository can't give GitHub Actions a bypass, so a creation rule would block it. Creating a tag still needs write access to the repository.

## Making a release

1. Open **Actions ▸ Release ▸ Run workflow**, keep the branch as `main`, and click **Run workflow**. The run's summary shows the version it will release.
2. Approve it under **Review deployments ▸ release**. Notarization usually takes a few minutes. If Apple rejects a build, the step prints Apple's log with the reason.
3. The release appears under Releases, and the website's Download button serves it.

From a terminal: `gh workflow run release.yml --ref main`.

**Dry run:** tick **Dry run** in the Run workflow form. It does the same build, sign and notarization, keeps the disk image as a workflow artifact for a week, and creates no tag or release.

**A new major or minor version:** in a pull request, run `Scripts/bump-version.sh minor` (or `major`, or an exact `2.1.0`), commit `VERSION`, and merge. Merging doesn't release anything; the next Release run releases `1.1.0`.

Tags are created only by the workflow. Don't push `v*` tags by hand: a stray tag would shift the next revision.

## How players get updates (and forks)

Each build records the GitHub repository it updates from as `DistillerUpdateRepository` in its Info.plist: in Actions, the repository running the workflow (`GITHUB_REPOSITORY`); locally, the checkout's `origin`; `DISTILLER_UPDATE_REPOSITORY` overrides it (empty turns update checks off). The app reads that repository's latest release, downloads `Distiller.dmg`, checks it against `SHA256SUMS.txt`, and installs it only if the app inside is signed by **the same team** as the running copy and notarized. So keep both assets in every release (the workflow does), and keep the `Distiller.dmg` name.

A fork that runs this workflow with its own Developer ID gets the same: its builds update from the fork's releases, signed by the fork's team. Copies from different teams never replace each other.

## Building a signed copy locally

`Scripts/bundle-app.sh` reads the same settings as the workflow:

```sh
DISTILLER_SIGN_IDENTITY="Developer ID Application: …" DISTILLER_HARDENED=1 \
DISTILLER_VERSION=1.0.3 Scripts/bundle-app.sh release
Scripts/make-dmg.sh dist/Distiller.app dist/Distiller-1.0.3.dmg "Developer ID Application: …"
NOTARY_KEY=AuthKey.p8 KEY_ID=… ISSUER_ID=… Scripts/notarize.sh dist/Distiller-1.0.3.dmg
Scripts/staple.sh dist/Distiller-1.0.3.dmg
```
