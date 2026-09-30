# Building and releasing

This guide is for contributors and release maintainers. Installation and everyday use are covered in [README.md](README.md).

## Build and test

Use an Apple silicon Mac with Apple's Command Line Tools (`xcode-select --install`). Full Xcode is unnecessary.

| Command | Result |
| --- | --- |
| `make build` | Builds and code-signs the app locally. |
| `make test` | Runs offline tests without accessing a monitor. |
| `make test-updater` | Tests Sparkle integration offline after the first build. |
| `make package` | Builds a signed ZIP and update feed using the release key in Keychain. |
| `APP_VERSION=1.0.1 make package` | Packages a specific version without editing source files. |

The first build downloads a pinned, checksum-verified Sparkle release. Output goes into `build/`; release assets go into `build/releases/vVERSION/`.

## Release signing

Building requires only the committed public key in `Resources/SparklePublicKey.txt`. Packaging and publishing also require its matching private key in the current user's Keychain.

Run `make setup-signing` to check the key. If no public key exists yet, setup creates a key pair and saves only the public key in the repository. If a public key already exists, setup requires the matching private key; it never silently replaces a project's signing identity.

Back up the private key securely outside the repository. On another release machine, import that key before packaging. Sparkle's [key backup and restore instructions](https://sparkle-project.org/documentation/#eddsa-ed25519-signatures) describe its `generate_keys` tool. Run `source scripts/common.sh` from the project root to access the tool at `"$SPARKLE_DIR/bin/generate_keys"`; pass `--account "$SPARKLE_ACCOUNT"` when exporting with `-x` or importing with `-f`.

The Keychain account defaults to the app's bundle identifier, which is a product identifier—not a macOS login. Set `SPARKLE_ACCOUNT` to use a different Keychain item holding the same release key. Never commit the private key.

## Publish to GitHub

1. Install [GitHub CLI](https://cli.github.com/) and run `gh auth login` with an account that can publish to the target repository.
2. Commit your changes. The release script requires a clean checkout, including untracked source files.
3. Run `make release VERSION=1.0.1` with a new stable version.

The script runs tests, packages and signs the app, tags the current commit, and pushes only that tag. It uploads to a draft, verifies the uploaded assets, then publishes the release as latest. It never creates commits or pushes a branch.

For custom notes or a draft:

```bash
bash scripts/release.sh 1.0.1 --notes-file release-notes.md --draft
```

Without a notes file, GitHub generates the release notes. Add `--dry-run` to check release prerequisites without building or publishing; this still uses the network. After a failed upload, rerun from the same commit to finish the draft. Published releases cannot be overwritten. Do not run overlapping release jobs.

Versions use `major.minor.patch` (major up to 9999, minor/patch up to 99). Keep published assets unchanged. Older installations without Sparkle need one manual update first.

## Repository configuration and forks

The default release repository comes from `SUFeedURL` in `Resources/Info.plist`. The authenticated GitHub user does not need to own that repository, but must have release permissions. The `origin` remote must match the selected repository.

For a fork, set `RELEASE_REPO=owner/repository` when building, packaging, or releasing. This selects both the publication destination and the app's update feed. For example:

```bash
RELEASE_REPO=example-owner/monitor-app make release VERSION=1.0.0
```

A separately distributed fork should establish its own bundle identifier and signing key before its first release. Keep the bundle identifier and signing key stable for an existing app so preferences and updates continue working. The feed and downloads must be publicly accessible.

## Optional Apple signing

Sparkle signatures verify updates; they do not remove Gatekeeper warnings. Builds use ad-hoc code signing by default.

To use Developer ID, install a certificate in Keychain and set `CODE_SIGN_IDENTITY` to its name. To notarize packages, also set `NOTARY_PROFILE` to a profile created with `xcrun notarytool store-credentials`. Packaging signs the app, submits it to Apple, staples the ticket, then signs the final ZIP and feed. This requires Apple Developer Program membership and network access.
