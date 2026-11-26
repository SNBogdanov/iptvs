# In-app updates — full detail

The app self-updates from its own **GitHub Releases** (`SNBogdanov/iptvs`; the `release.yml`
pipeline attaches `iptvs-<ver>-android.apk`, `iptvs-<ver>.msi`, `iptvs-<ver>-linux-x86_64.AppImage`
and an **`update.json`** manifest to a `v<ver>` tag).
The compact rules live in CLAUDE.md; read this before changing the update flow, the release
pipeline, or the update dialog.

The manifest shape follows `tremotesf`: one object per platform with a direct URL, byte size and
SHA-256, read from `releases/latest/download/update.json` (no GitHub API, no rate limit, no
signature — the trust anchor is HTTPS to GitHub plus the per-file hash):

```json
{
  "version": "1.2.3",
  "minimum_version": "1.0.0",
  "windows": {"url": "…/iptvs-1.2.3.msi", "size": 73422891, "sha256": "…"},
  "android": {"url": "…/iptvs-1.2.3.apk", "size": 55123456, "sha256": "…"},
  "linux":   {"url": "…/iptvs-1.2.3.AppImage", "size": 81234567, "sha256": "…"}
}
```

There is no `windows.cert`: an MSI needs no publisher trust to install. The old field named the
certificate the updater imported into `Cert:\LocalMachine\TrustedPeople` before `Add-AppxPackage`;
the MSIX path, and that field with it, is gone.

## Cutting one

Two routes, and **the tag is what the release is addressed by either way**. Pushing a `v<ver>` tag
runs the pipeline directly. A manual `workflow_dispatch` (the only way to reach the `beta` track)
takes the version as an input and **creates the tag itself** at the dispatched commit, because the
publish step runs `gh release create --verify-tag` and refuses a tag that does not exist — a
dispatch without that step builds all three platforms and then aborts at the last one.

That step probes for the tag with a **REST status check**, the same idiom the publish step uses
for the release itself and for the same reason: `gh api --jq` prints a 404's error body to
*stdout*, so a missing tag came back as the string `{"message":"Not Found",...}` and the guard
read every absent tag as an existing one — a dispatch could never create its own tag, and died
here with `already exists at {"message":"Not Found"...}`. Only a real HTTP 404 counts as absent;
anything else is transient and fails the step rather than being mistaken for it.

That step never *moves* an existing tag. A published release is addressed by it, users may already
hold the artifacts it named, and `update.json` names one exact build (URL + size + SHA-256) — so a
tag that exists at a different commit is a hard failure asking for a new version instead.

## Release changelog

The release body opens with a short **AI-generated changelog** (release.yml's "Generate AI
changelog" step: commit subjects since the previous tag → Gemini, key in the `GEMINI_API_KEY`
repo secret → `--notes-file`), with GitHub's auto-generated notes appended below. It tries
`gemini-3.5-flash` → `gemini-3.1-flash-lite` → `gemini-3-flash-preview` (two attempts each — the
primary 503s under load, which cut v0.1.29 without a changelog). The step is fail-open — no key /
no previous tag / API error just yields the auto notes — and the body is what the in-app update
dialog renders.

## Release publishing

The publish step drives the `gh` CLI directly with per-command retries (5 attempts, linear
backoff) — a GitHub API 503 mid-publish previously failed the whole job. Release existence is
probed with a raw `gh api` status check because `gh release view` reports "release not found"
for *any* REST failure, so an outage would misroute an existing release into `gh release
create` and a persistent "already exists" error; only a real HTTP 404 selects the create path,
anything non-404 goes back through retry. Re-runs converge: an existing release is edited
(title/notes/prerelease) and assets re-uploaded with `--clobber`, and an empty AI-changelog
body never overwrites an existing release's notes on the edit path. `--verify-tag` keeps a
manual dispatch from minting a release for a tag that was never pushed.

### What the pipeline needs

| Kind | Name | What it is |
|---|---|---|
| secret | `ANDROID_RELEASE_KEYSTORE_BASE64` | `secrets/iptvs-release.jks`, base64-encoded |
| secret | `ANDROID_RELEASE_KEYSTORE_PASSWORD`, `ANDROID_RELEASE_KEY_ALIAS`, `ANDROID_RELEASE_KEY_PASSWORD` | keystore credentials |
| var | `ANDROID_RELEASE_CERT_SHA256` | expected APK signer fingerprint (see `docs/android-signing.md`) |
| var | `SUPABASE_URL`, `SUPABASE_ANON_KEY` | cloud sync (empty in a plain fork → the feature stays off) |
| secret | `GEMINI_API_KEY`, `DISCORD_RELEASE_WEBHOOK` | optional changelog / announcement |

The Android job fails when its keystore secrets are missing rather than publishing an unsigned APK.
Windows needs **no secrets**: the MSI is not signed, it installs per-machine without certificate
trust (see "Manifest and package signing"). Assets attached to the tag:
`iptvs-<ver>-android.apk`, `iptvs-<ver>.msi`, `iptvs-<ver>-linux-x86_64.AppImage`, and
`update.json`. Nothing signs the manifest any more — the Ed25519 secrets and the
`UPDATE_MANIFEST_PUBLIC_KEY` variable are gone, together with the `--dart-define` that embedded the
public key.

## Discord announcement

The last step of the publish job posts the release to Discord (`DISCORD_RELEASE_WEBHOOK` repo
secret; the step is skipped when it is absent, so forks neither post nor fail). Three things
about it are deliberate:

- **It runs after `gh release upload`, not before.** An announcement that lands before the
  assets exist points people at a release with nothing attached, and the upload is the step
  most likely to need a retry.
- **It reuses `body.md`** — the same Gemini changelog that becomes the release notes and feeds
  the in-app update dialog — so the three never disagree. That file is empty whenever the
  changelog step failed open, which is handled rather than posting a blank embed.
- **It is fail-open and payload-safe.** The release is already published by the time it runs, so
  a Discord outage logs a warning instead of turning a successful release red. The description
  is truncated to Discord's 4096-character embed cap (a longer changelog would otherwise get the
  *whole payload* rejected), and the JSON is built with `jq --arg` so markdown quotes, newlines
  and backslashes cannot break or inject into it.

GitHub-direct builds expose a Stable/Beta selector in settings. **This fork publishes one channel**:
both values read `releases/latest/download/update.json`, and GitHub's `latest` excludes prereleases,
so a `beta` dispatch is downloadable from the release page but never auto-served. Development and
AltStore builds do not run or show the GitHub updater (`ownsDirectUpdates`), and there is no store
build at all — this fork has no Google Play or Microsoft Store publishing path.

## Adding a release platform (forward-compatibility)

`update.json` carries one object per platform under a lowercase key, and a client reads only the
keys in `kReleaseManifestKeys` (`android`, `windows`, `linux`). Unknown keys are **ignored** — the
tolerant parser is what makes adding a platform safe.

That tolerance is worth keeping because its absence was catastrophic once. The predecessor of this
parser was fail-closed: a manifest with any unknown platform threw, and the client rejected the whole
thing. 0.1.38 was the first release to add a `linux-x86_64` artifact, so every ≤0.1.37 client (strict
`{android, windows-x64}` parser) failed to parse the manifest — on Windows and Android too, not just
Linux — and auto-update went down for all of them.

Rules when introducing a new platform artifact into the manifest:

- **Adding a key is safe only while clients ignore unknown keys.** Every release ≥0.1.38 does; a
  build older than that cannot be fixed remotely, because the broken parser is baked in and
  auto-update is exactly what is down. A fork whose users all run a modern build (this one) has no
  such cohort, but the rule still holds for anything published to the upstream population.
- **Rescue path for an already-broken cohort:** cut a release whose manifest lists *only* the keys
  the stuck parser accepts, so `/latest` serves them something they can parse and lands them on a
  tolerant build. Cost: the newly-added platform gets no auto-update for that release and must
  update manually once (its installs are new and treat a missing entry as "no asset", not a crash).
  Restore the full manifest once the old cohort has drained.
  **Status:** the 0.1.38 rescue is complete — every relevant install has the skip-unknown parser, so
  `linux-x86_64` is published normally again.

## Layering

Layered like everything else — a shared Dart service does the network check + version compare;
the final install step is the only platform-specific part.

- **`lib/data/update_manifest.dart`** — the `update.json` schema: `version`, `minimum_version`,
  and one object per platform with `url` (HTTPS), `size` and `sha256`. Values are validated
  (file extension per platform, hash shape, size ceilings) and **unknown platform keys are skipped,
  not rejected**
  (`kReleaseManifestKeys`): the parse loop ignores keys this build does not recognise, so a
  release that adds a platform cannot break an older client — the fail-closed behaviour this
  replaced once rejected a whole manifest over one unknown platform. There is **no signature**;
  see "Manifest and package signing" below.
- **`lib/data/update_service.dart`** — `ReleaseInfo` and `UpdateService.fetchLatest()`, which GETs
  `https://github.com/SNBogdanov/iptvs/releases/latest/download/update.json` (GitHub's own redirect
  to the newest non-draft, non-prerelease release — no API, no rate limit; 404 = "no releases yet"
  = up to date, not an error) and builds the platform assets from it. `appVersion()` (via
  `package_info_plus` — the CI build-name, i.e. the tag minus `v`, so a release build reports
  `1.2.3` and compares equal to tag `v1.2.3`; local `flutter run` builds report the pubspec
  `1.0.0`), and the pure `compareVersions` / `isNewer` / `shouldAutoCheck` (unit-tested in
  `test/update_service_test.dart`). `UpdateTrack` is retained for the settings UI, but this fork
  publishes one channel: both values read the same asset.
- **`lib/data/update_store.dart`** — `skippedVersion` + `lastCheck` prefs in the keychain
  (mirrors `LocalProfileStore`; the app has no SharedPreferences), plus the authenticated
  metadata/path for a fully downloaded Android APK awaiting user installation. The pending
  record is cleared after the installed version catches up or when cache revalidation fails.
- **`lib/data/update_installer.dart`** — `download()` permits only HTTPS GitHub release hosts and
  approved redirect hosts, streams to a `.partial` temp file with a signed-size ceiling, verifies
  exact received length and SHA-256, and only then renames it to the install filename. Failure
  deletes the partial file. It then hands the verified file to the platform: **Android** fires the
  system package-installer over the **`iptvs/updates`** MethodChannel (`installApk`) only after
  native code confirms the APK is inside this app's cache, has the same package name, and has the
  same signing-certificate set as the installed app. Installation needs the
  `REQUEST_INSTALL_PACKAGES` permission + a **FileProvider** (`${applicationId}.fileprovider`,
  `@xml/file_paths` → `<cache-path>`, since `getTemporaryDirectory()` = the Android cache dir) —
  falls back to `requestInstallPermission` (unknown-sources settings) or the browser. The
  permission call completes only when Android returns from settings, allowing the same APK to be
  retried without a second download. Any later resume rechecks the cache-owned path, exact byte
  length, and SHA-256 before native package/signer verification runs again; **Windows** downloads
  the `.msi`, verifies its size and SHA-256, and writes a PowerShell helper
  (`windowsMsiUpdateScript`) that waits for our PID (`msiexec` cannot replace files a running
  process still holds), runs `msiexec /i <msi> /qn /norestart /l*v %TEMP%\iptvs_msi.log`, treats
  exit codes `0` and `3010` as success, and relaunches the installed `iptvs.exe` from
  `HKLM\SOFTWARE\SNBogdanov\IPTVS\InstallDir` — the value the MSI itself writes, with
  `C:\Program Files\IPTVS` only as a fallback for a machine whose registry entry was cleaned away.
  The helper is spawned **elevated** (`windowsUpdaterLaunch` -> `Start-Process -Verb RunAs`,
  the UAC prompt the user sees), because a per-machine MSI installs into Program Files; the app
  `exit(0)`s right after, so the files are not held open. A `Start-Transcript` lands in
  `%TEMP%\iptvs_update.log`, and a failed run exits non-zero instead of silently no-opping. MSI
  upgrades **in place**: `MajorUpgrade` with the package's permanent `UpgradeCode` removes the
  previous version in the same transaction, so the old install never coexists with the new one and
  a failed install rolls back to it. `flutter run` and an unpacked folder are not what the MSI
  upgrades, so they fall back to the release page. **Linux** copies the verified AppImage beside the
running `APPIMAGE`, then a detached POSIX helper waits for our PID, atomically
swaps the file, relaunches it, and restores the backup if startup fails. Linux
in-app updates are available only from a writable AppImage; `flutter run` and
system-installed binaries fall back to the release page.
- **`lib/screens/update_flow.dart`** — `runUpdateCheck(context, manual:)` drives prompt →
  download → install (the "Update available" dialog with **Skip this version / Later / Update**,
  and the progress dialog). Entry points: a **manual** "Check for updates" `FocusableCard` on
  `sources_screen.dart` (`_UpdateCard`), and a **throttled startup** check in `home_shell.dart`
  (post-frame, release platforms only, honours the skipped version). Android records a verified
  APK before launching the system installer. Returning after an OEM Auto Blocker/settings detour,
  or recreating the app process, presents a **ready to install** prompt that reuses the cached APK;
  an already-upgraded app silently clears the pending record.

## D-pad behaviour

Each dialog's **primary action autofocuses** (so a TV remote's OK acts immediately — the modal's
focus scope otherwise lands on nothing until an arrow press), and the progress dialog carries an
autofocused **Cancel** (a focus target on TV + aborts a slow download; remote/system Back cancels
too). The "Update available" dialog (`_UpdateDialog`) **traps D-pad focus**: a boundary `Focus`
consumes bare Up/Down (they previously fell through the modal barrier onto the channel list
behind it on a TV) and cycles them between the actions and a focusable, scrollable changelog
rendered by `ReleaseNotesView` (formatted, not raw markdown). The public `showUpdateDialog` /
`UpdateChoice` exist so `test/update_dialog_test.dart` can pin the autofocus + focus-trap
behaviour.
The cached-update prompt follows the same primary-action rule: **Install** autofocuses, while
**Later** keeps the verified pending record for the next resume.

## Manifest and package signing

**The manifest itself is not signed.** `update.json` is read over HTTPS from GitHub's release CDN
and every artifact it names is checked against the size and SHA-256 it carries; a signature shipped
next to the file it authenticates would add little over that, and the previous Ed25519 manifest
needed a private key this fork does not have (its public key was compiled into upstream builds, and
`setup_update_signing.sh` generated the pair for upstream's `release` environment).

What *is* signed is the Android APK (`docs/android-signing.md`). The Windows **MSI is not signed**:
it installs per-machine without any certificate trust, so there is no `.cer` asset and no
`TrustedPeople` import. What must never change instead is the package's `UpgradeCode`
(`{B2F1C0DE-3E4A-4C55-9B7E-1D5C2A8F6E31}`, in `windows/packaging/Product.wxs.in`): it is what tells
Windows that a new release replaces this product, and changing it turns every release into a second
parallel install with the old one left behind — the MSI equivalent of the MSIX identity trap. The
install directory `C:\Program Files\IPTVS` is equally permanent: the updater relaunches from the
`HKLM\SOFTWARE\SNBogdanov\IPTVS\InstallDir` value the package writes.

`tool/package_windows_msi.ps1` builds the package with WiX v4 (pinned 4.0.6, with its
`WixToolset.UI.wixext` UI extension)
from the Flutter Release payload, adding one component per file. The wizard is WixUI with our own
fonts and artwork, a folder/shortcut page for the first install, an "Upgrade" notice when
`FindRelatedProducts` found an older version, and a Repair/Remove page (no Change — the feature set
is fixed) reachable from "Изменить" in Programs and features. `ARPNOREMOVE` is set so removing the
app happens on that page, where it can say that sources, history and settings are kept.

Android APK signing is separate and documented in `docs/android-signing.md` (the fork's permanent
keystore, `CN=IPTVS`, SHA-256 `333b31f4…25aa6f`). Keep two offline copies of it.
