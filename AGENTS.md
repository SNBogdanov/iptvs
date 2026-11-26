# Build/deploy workflow

- Build/deploy only via subagents `iptvs-build` / `iptvs-deploy`.
- The main session does not run `flutter build`, packaging or copy commands itself:
  it asks for targets, invokes the agent, and reads the report.
- Pass all targets of the current stage at once (`windows` / `android` / `linux`).
  The build agent runs them in one invocation; do not return to the main session
  between targets.
- `CLAUDE.md` remains the source of truth for commands, the verification gate and
  platform-specific rules.
- Deploy: check whether `iptvs.exe` is running (`Get-Process iptvs`). If it is, do not kill
  it — rename locked files to `<name>.old.<timestamp>`, copy the new ones, and remind the
  user to restart. Close the process only if renaming is impossible and the user agrees.

## Release cycle (standing rule)

When the user says **«сборка release»**:

1. **Bump the version by one** in `pubspec.yaml`: patch `+1` (`1.0.1+2` →
   `1.0.2+3`). The version name is the only thing that moves — Android's
   `versionCode` is derived from it in `android/app/build.gradle.kts`
   (`1.0.2` → `1_000_002`), so a release is always a higher code than every
   earlier one and upgrades installed builds in place. A published version is
   never reused.
2. Build the release after the full gate (`flutter analyze` + full `flutter test`):
   Android `githubDirect` APK signed with `secrets/iptvs-release.jks`, Windows MSI
   (WiX v4, `tool/package_windows_msi.ps1`), Linux AppImage.
3. **Publish to GitHub**: commit (via `/commit`), tag `v<version>`, push branch and
   tag, so `release.yml` publishes the release with `update.json` and the assets.

**After a release, until the next one**, the version is frozen and every iteration
build carries it with the **release signature**, so the phone keeps exactly one
installation:

- **debug** builds use the release key too (`debug` signing config = `release` in
  `build.gradle.kts`, falling back to the public debug key only when no keystore is
  configured): `flutter build apk --debug --flavor githubDirect`, package
  `io.github.snbogdanov.iptvs.direct`;
- release builds: `--release --flavor githubDirect`.
- Install over the previous build with `adb install -r` on the phone **Note**
  (`RF8N30P85JJ`). **Never `--split-per-abi`** for anything installed on a device:
  the ABI offset changes `versionCode` and breaks the in-place upgrade chain.
- `development` (`.dev`, debug key when no keystore is present) is a separate app
  id and does not go on the Note.
