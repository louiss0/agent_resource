# Releasing Agent Resource

Releases use GoReleaser OSS with a small Dart build adapter. Dart compilation
runs on native Windows, macOS, and Linux jobs. A final Linux job imports the
same qualified binaries, creates archives and checksums, publishes the GitHub
release, updates the Homebrew tap, and opens a WinGet pull request.

The first release targets Windows x64, macOS ARM64, and Linux x64. Installed
executables do not require a Dart SDK.

## Prerequisites

1. Resolve every blocker and complete the human approval in
   `docs/release-qualification.md`. A tag must not be used to bypass that
   decision.
2. Ensure `louiss0/homebrew-the-code-fixer-23` exists and can receive casks in
   its `Casks/` directory.
3. Fork `microsoft/winget-pkgs` as `louiss0/winget-pkgs`.
4. Create a `release` GitHub environment with required reviewers. The publish
   job uses this environment, so an approved automated evidence bundle still
   waits for explicit human approval before any external publication.
5. Add a `RELEASE_TOKEN` repository secret. The token must be able to push to
   both external repositories and open pull requests from the WinGet fork to
   `microsoft/winget-pkgs`. The workflow's ordinary `GITHUB_TOKEN` publishes
   only the GitHub release; it is not used for cross-repository writes.
6. Set `pubspec.yaml`'s `version` and the default `applicationVersion` in
   `lib/agent_resource.dart` to the intended release version. The release
   workflow rejects a tag whose version differs from `pubspec.yaml`.

The current macOS binaries are unsigned and unnotarized. The generated cask
explains the explicit quarantine-removal option; the workflow does not bypass
Gatekeeper automatically.

## Local validation

Install Dart 3.13.2 and GoReleaser 2.14.3, then run:

```text
dart pub get --enforce-lockfile
dart format --output=none --set-exit-if-changed lib bin test tool
dart analyze
dart test
goreleaser check
mkdir -p build/native
goreleaser build --snapshot --clean --single-target --id agent_resource_windows --output build/native/agent_resource.exe
```

On macOS, use build ID `agent_resource_darwin` and output
`build/native/agent_resource`; on Linux, use `agent_resource_linux` and the
same extensionless output. The adapter injects GoReleaser's snapshot or tag
version into the executable.
`dist/` contains GoReleaser's ordinary build output and is not committed.

## Publish

After committing and pushing the release candidate, tag the approved revision:

```text
git tag -a v0.1.0 -m "Agent Resource v0.1.0"
git push origin v0.1.0
```

The tag workflow performs these stages:

1. **Build and qualify:** each native job checks formatting, analysis, tests,
   and the version, builds through GoReleaser, smokes `--version`, and runs the
   production release gate with `--require-qualified`.
2. **Release decision:** the existing aggregator requires all three native
   evidence bundles and their mandatory scenarios.
3. **Publish:** after the protected `release` environment receives human
   approval, GoReleaser imports only the retained qualified executables,
   packages `.tar.gz` archives for macOS/Linux and a `.zip` archive for
   Windows, and creates `checksums.txt`.

GoReleaser then creates the GitHub release, writes
`Casks/agent-resource.rb` to `louiss0/homebrew-the-code-fixer-23`, and opens a
WinGet PR from `louiss0/winget-pkgs` to `microsoft/winget-pkgs`. WinGet
installation becomes available only after Microsoft reviews and merges that
PR. Prerelease tags generate the release artifacts but skip both external
uploads through `skip_upload: auto`.

## Install a published release

```text
brew tap louiss0/the-code-fixer-23
brew install --cask agent-resource
```

After the WinGet PR is merged:

```text
winget install --id louiss0.AgentResource --exact
```
