---
title: Installing
description: Where to get iptvs for Windows, Android, Android TV and Linux, and how updates work on each.
---

iptvs runs on Windows, Android (phones and tablets), Android TV, and Linux.

## Android and Android TV

Download the APK from the
[releases page](https://github.com/SNBogdanov/iptvs/releases).

There is **no store build**: an APK from Google Play (or from the original upstream
project) is a *different app* signed with a different certificate, and Android
refuses to update one with the other. To switch, uninstall first; your sources are in the device
keychain and will be gone with the app, so
[pair with the cloud panel](/guides/cloud-sync/) first if you want them back
without retyping.

On Android TV, sideloading the APK usually means enabling "install unknown apps"
for whichever file manager you used.

## Windows

Download the `.msi` from the [releases page](https://github.com/SNBogdanov/iptvs/releases)
and open it. Windows installs the package; the first install asks you to trust the
publisher's certificate (the in-app updater imports it again, elevated, when a new
machine updates).

The MSI updates itself in place from within the app: it downloads the new version,
verifies its size and hash, and hands it to `Add-AppxPackage`.

## Linux

Download the AppImage from the releases page, mark it executable, and run it.

**mpv must be installed on the host** — the AppImage deliberately does not bundle
it, so it uses your distribution's build and your GPU drivers. Version 0.40 or
newer is required; 0.41 is recommended.

```sh
sudo apt install mpv        # Debian / Ubuntu
sudo dnf install mpv        # Fedora
sudo pacman -S mpv          # Arch
```

If the AppImage is somewhere writable it can update itself in place; if you put
it somewhere root-owned, update it the way you installed it.

## Updates

Outside the stores, the app checks for its own updates and offers them in a
dialog. Every download is verified against a signed release manifest before it
is installed — filename, size and hash all have to match — so a partial or
tampered download is refused rather than run.
