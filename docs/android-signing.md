# Android Release Signing

This document records the signing recovery, permanent release-signing rules,
and the evidence required before changing the Android package identity.

## Confirmed release history

The public GitHub release `v0.1.30`, published on 2026-07-14, contains
`iptvs-0.1.30-android.apk` with SHA-256:

```text
8cbbc6254243f6a39b2d7f9ddf051010eb1b4502639f2f5dee99b3c08177eb75
```

`apksigner verify --verbose --print-certs` reports:

```text
Certificate subject: CN=Android Debug, O=Android, C=US
Certificate SHA-256: CF:3C:C3:53:C7:02:B4:D5:48:E7:4C:75:32:25:61:2C:4E:AA:D9:4A:E0:E9:FB:D4:1C:BE:4A:C6:9C:85:3E:EC
Signature scheme: v2
```

That fingerprint matches `android/app/debug.keystore`. The Gradle files at both
the first public tag (`v0.1.0`) and latest inspected tag (`v0.1.30`) assign this
debug configuration to the release build type. Existing direct-download installs
must therefore be treated as signed by a publicly available private key.

## Recovery decision

Status: **transition selected; Play migration verified, direct release
verification pending**.

Known distribution:

- GitHub Releases publishes a directly installable universal APK.
- Existing GitHub APKs use application ID `com.gchofficial.iptvs`.
- Google Play internal testing now has an enrolled Play App Signing population.

The first Play internal-testing AAB and a subsequent update were accepted on
2026-07-15. No public Play artifact has shipped.

The selected recovery uses separate new identities:

| Distribution | Application ID | Update owner |
|---|---|---|
| Existing compromised GitHub APK | `com.gchofficial.iptvs` | Retired |
| New GitHub direct Stable/Beta | `com.gchofficial.iptvs.player.direct` | Signed GitHub updater |
| Google Play | `com.gchofficial.iptvs.player` | Google Play |
| Local development | `com.gchofficial.iptvs.player.dev` | None |

**This fork publishes under its own identity: `io.github.snbogdanov.iptvs`**
(flavour suffixes: `.dev` and `.direct`). It is
a *different app* to Android: it does not update any `com.gchofficial.iptvs.player*`
install, and none of those update it, so
state has to come back through cloud pairing or an explicit export. The upstream
Play and outside-Play registrations in the table above are upstream's — they
cannot be used by this fork, which ships through GitHub releases only and has no
store listing at all. The Kotlin `namespace` deliberately stays `com.gchofficial.iptvs`; the
code package is not the app identity.

The new GitHub and Play applications install beside both the old app and each
other. This prevents signer/version conflicts and lets Store packages omit the
self-updater. User state must be restored through authenticated cloud sync or an
explicitly encrypted user-controlled export. Signing lineage is not a secure
recovery from a public private key: another holder of that key can authorize a
different lineage.

Keeping `com.gchofficial.iptvs` with a new certificate is suitable only for clean
installs or a deliberately documented uninstall/reinstall transition. Android
will reject it as an in-place update for existing direct-download installations.

The Google Play application and its Play-managed app-signing key belong to
upstream's release process, not this fork. This fork has **no store publishing
path**: the `googlePlay` Gradle flavour, the Play upload pipeline and the
store-signing environments were removed, so the only Android artifact is the
GitHub-direct APK signed with the key recorded below. Never supply that key to a
store — a store builds its own signing identity, and its updates are its own.

On 2026-07-16, Android developer verification registered both active release
identities. `com.gchofficial.iptvs.player` is registered with Google's
Play-managed app-signing certificate
`F4:D9:F8:2B:A1:DB:51:94:19:D4:9C:2B:7D:39:AA:A5:F0:10:A8:92:CB:F0:37:1A:AE:01:30:41:6E:DB:37:53`.
The outside-Play `com.gchofficial.iptvs.player.direct` package is registered
separately with the permanent direct-distribution certificate recorded below.
On 2026-07-16, the base APK of the internal-track app installed by Play on an
SM-S938B was pulled with `adb` and checked with
`tool/verify_android_apk_certificate.sh`; `apksigner` reported the exact
Play-managed SHA-256 fingerprint above.

## User-data transition from the retired app

Android deliberately isolates application data by application ID and signing
identity. Therefore neither `com.gchofficial.iptvs.player` nor
`com.gchofficial.iptvs.player.direct` can read the retired
`com.gchofficial.iptvs` app's secure storage or SQLite database. Installing a
new app beside the old one does not migrate anything automatically, and the old
app must not be uninstalled until the user has verified the replacement.

The supported migration is authenticated cloud sync, not a plaintext source
export:

1. In the old app, pair Cloud Sync with the user's panel account.
2. Select or create the destination cloud profile and use **Push to panel**.
   This pushes the complete source list, per-source settings such as hidden
   categories, metadata-provider configuration, and live/movie/series
   favorites.
3. Install the new Play or GitHub-direct app side by side, pair it with the same
   account, select the same cloud profile, and pull.
4. Compare source counts and representative favorites, then test playback before
   removing the old app.

Cloud sync does **not** transfer device-local profile names, the active source,
EPG/media caches, diagnostics, or update preferences. VOD/series playback
positions and watched marks **do** follow the paired cloud profile (they sync as
a per-title delta), but only for sources that profile manages — a local-only
source's progress stays on the device. Those other values start fresh. Users who
do not opt into cloud sync must re-enter their source configuration manually;
there is intentionally no credential-bearing plaintext export. The two new
identities also remain isolated from each other, so the same cloud procedure is
required when moving between Play and GitHub-direct installations.

## Permanent build rules

- Debug builds may use `android/app/debug.keystore` and are non-distributable.
- The normal build workflow compiles a debug smoke APK and does not upload it.
  It also runs one `githubDirect` **release** build, only so release lint
  (`lintVital*`, which debug builds skip) gates every PR. That build gets the
  signing variables pointed explicitly at the public `debug.keystore`, and the
  APK is deleted, never uploaded. This is not a fallback: the release config
  still refuses to configure without all four variables, and a debug-signed
  APK cannot be published because the release workflow's certificate check
  rejects it. Keep it that way: never give that step a real key.
- Release builds never fall back to the debug signing configuration.
- A release task fails when any signing environment variable is absent.
- The release workflow verifies the built APK certificate against a separately
  configured expected SHA-256 fingerprint before uploading it.
- Private keystores, passwords, and `key.properties` files are never committed.

### The fork's signing key

This fork has its **own permanent release key**, generated 2026-11-26 and kept
out of the repository:

| Field | Value |
|---|---|
| Keystore | `secrets/iptvs-release.jks` (PKCS12, gitignored) |
| Alias | `iptvs` |
| Subject | `CN=IPTVS, OU=Android, O=SNBogdanov, C=RU` |
| Key | RSA 4096, `SHA256withRSA`, validity 10 000 days (until 2054-04-13) |
| Certificate SHA-256 | `33:3B:31:F4:29:5F:6D:7D:4C:25:EB:98:7A:6E:9B:92:39:DD:E9:F4:1E:FB:83:97:BD:2B:B5:CE:E6:25:AA:6F` |
| Certificate PEM | `secrets/iptvs-release-cert.pem` |
| Password | `secrets/iptvs_android_keystore_password.txt` (same value for store and key) |

`android/keystore.properties` (gitignored) points at it, so a local
`flutter build apk --release` signs with this key when the CI variables below
are absent. **Back this keystore up** (two offline copies): it is the package's
identity — losing it means no future release can update an installed build, and
losing it while someone else holds a copy means they can sign as the same app.

For CI, base64 the keystore into the protected `release` environment secret
`ANDROID_RELEASE_KEYSTORE_BASE64` and put the same alias/passwords in
`ANDROID_RELEASE_KEY_ALIAS` / `ANDROID_RELEASE_KEYSTORE_PASSWORD` /
`ANDROID_RELEASE_KEY_PASSWORD`.

The old `android/keystore.jks` (alias `tremotesf`, `CN=Tremotesf Parallel`) is
**retired**: it signed earlier local `.parallel` builds, which this fork no
longer produces.

The side-by-side `parallel` flavour was **removed**: this fork already has its
own application id (`io.github.snbogdanov.iptvs`), so a `.dev` or `.direct`
build installs beside an upstream package without a third identity to maintain.
The phone that keeps the fork's own release (`Note`) runs the `.direct` flavour
only — debug and release alike, signed with the same key, so the install is
replaced in place rather than duplicated:

```bash
flutter build apk --debug   --flavor githubDirect   # iteration build, release-signed
flutter build apk --release --flavor githubDirect   # what a release ships
```

The `development` flavour (`io.github.snbogdanov.iptvs.dev`) is a separate app
id: useful for a truly throwaway build, never for updating the Note.

#### `versionCode` is derived from the version name

`android/app/build.gradle.kts` computes `versionCode` with `versionCodeFromName`
(`1.0.2` → `1_000_002`) and ignores Flutter's `--build-number`/`+N`. Two build
paths producing different codes for the same version is what made in-place
upgrades unreliable: a `--split-per-abi` arm64 build of `+1` got code 2001 while
the universal release got 1, so the "new" APK could be a downgrade. With the
derived code, every build of a version shares one code and every release is
higher than all earlier ones — so **never install a `--split-per-abi` APK on a
device**, because the ABI offset changes the code again.

#### Debug builds carry the release signature

`buildTypes.debug` uses the `release` signing config when one is configured
(CI env vars or `android/keystore.properties`), falling back to the committed
public debug key otherwise — so PR CI, which has no secrets, keeps working. The
point is a single installation per device: `flutter build apk --debug --flavor
githubDirect` has the same application id (`.direct`), the same version name and
the same signer as the release build, so `adb install -r` replaces it in place
and no second copy appears. A `development` (`.dev`) build is still a different
app and cannot update it.

#### Local Android toolchain on this machine

`flutter doctor` does not find the SDK by itself here; the working environment
(the one local release builds were verified with) is:

```powershell
$env:ANDROID_HOME      = 'C:\Users\SERGEYBO\Documents\Projects\_tools\android-sdk'
$env:ANDROID_USER_HOME = 'C:\Users\SERGEYBO\Documents\Projects\_tools\android-user-home'
$env:JAVA_HOME         = 'C:\Users\SERGEYBO\Documents\Projects\_tools\jdk21\jdk-21.0.13+9'
```

`ANDROID_USER_HOME` matters because this shell runs as `LOCAL SERVICE`: without
it, sdkmanager tries `C:\Users\SERGEYBO\.config\.android` (not writable) and
fails with a misleading "failed to download source lists". JDK 21 is used
because newer JDKs trip Gradle's "newer than known valid Java version". AGP
then installs NDK r28c and platforms 35/36 on demand.

Required Gradle environment variables:

```text
IPTVS_ANDROID_KEYSTORE_PATH
IPTVS_ANDROID_KEYSTORE_PASSWORD
IPTVS_ANDROID_KEY_ALIAS
IPTVS_ANDROID_KEY_PASSWORD
```

Required protected GitHub `release` environment configuration:

| Type | Name |
|---|---|
| Secret | `ANDROID_RELEASE_KEYSTORE_BASE64` |
| Secret | `ANDROID_RELEASE_KEYSTORE_PASSWORD` |
| Secret | `ANDROID_RELEASE_KEY_ALIAS` |
| Secret | `ANDROID_RELEASE_KEY_PASSWORD` |
| Variable | `ANDROID_RELEASE_CERT_SHA256` |

Configure required reviewers on the `release` environment. Build jobs receive
read-only repository access; only the final publish job receives
`contents: write`.

## Creating the permanent key

This fork's direct-distribution key (`secrets/iptvs-release.jks`, **not** committed) was
generated outside the repository. Its non-secret identity is:

```text
Alias: iptvs
Certificate subject: CN=IPTVS, OU=Android, O=SNBogdanov, C=RU
Certificate SHA-256: 33:3B:31:F4:29:5F:6D:7D:4C:25:EB:98:7A:6E:9B:92:39:DD:E9:F4:1E:FB:83:97:BD:2B:B5:CE:E6:25:AA:6F
```

(The key this fork replaced — `CN=iptvs, O=George-Cosmin Hanta, C=RO`,
`6E:36:3B:97…4A:50:D5:3B` — belongs to upstream and signs nothing here.)

The four signing secrets and `ANDROID_RELEASE_CERT_SHA256` variable are
configured in the GitHub `release` environment. Passwords and keystore contents
must never be copied into this document.

Generate a new key on a trusted offline machine, outside the repository:

```bash
keytool -genkeypair -v -keystore iptvs-release.jks -alias iptvs \
  -keyalg RSA -keysize 4096 -validity 10000
```

Record the public certificate fingerprint:

```bash
keytool -list -v -keystore iptvs-release.jks -alias iptvs
```

Encode the keystore for the GitHub secret without printing it into logs:

```bash
base64 -w0 iptvs-release.jks > iptvs-release.jks.base64
```

Keep at least two encrypted offline backups. Loss of the signing key prevents
future direct-download updates; disclosure allows malicious replacement APKs.

## Verification checklist

- [x] Store/distribution inventory is complete.
- [x] Package-ID transition is selected and documented.
- [x] User-data migration behavior is tested with the Play internal build;
  cloud sources/favorites restored and documented device-local exclusions began
  fresh.
- [x] Permanent signing key is generated outside the repository.
- [x] At least two encrypted offline backups of the permanent key and credentials
  are confirmed by the owner.
- [x] Protected environment secrets and expected fingerprint are configured.
- [x] `flutter build apk --debug --flavor development` succeeds without release
  secrets.
- [x] `flutter build apk --release --flavor githubDirect` fails without release
  secrets.
- [x] A secret-backed release build succeeds with a disposable `/tmp` validation
  key; this does not replace creation of the protected permanent key.
- [x] `apksigner` reports the disposable validation fingerprint, proving the
  Gradle environment-variable path signs the output.
- [x] A protected GitHub release run reports the permanent fingerprint above.
- [x] A minimum-SDK (API 26) install/start smoke test passes. Current API 36
  phone/TV and Play internal-update paths are verified; every intermediate API
  is not required as an early-testing gate.
