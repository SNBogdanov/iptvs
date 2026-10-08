# Vendored `media_kit_video`

This is an unmodified-except-where-noted copy of **`media_kit_video` 2.0.1** from
pub.dev, kept in-tree so the Windows renderer's fix travels with the repo.
Upstream is unmaintained for this defect and has no release carrying it, so the
patch lives here rather than as an override we cannot express.

- Upstream: <https://pub.dev/packages/media_kit_video/versions/2.0.1>
- Copied from the pub cache, minus `example/` (a sample app nothing here builds).
- Everything outside `windows/` is byte-identical to upstream.
- `pubspec.yaml` differs only by `publish_to: 'none'` (this copy must never be
  published) and the `description` pointing here.

Every edit below is marked in the source with an `// iptvs patch:` comment.

## Why

The Windows texture callbacks are `std::function`s that **the Flutter engine
calls directly** on the raster thread. `VideoOutput::Resize` unregisters the
previous texture and its release callback erases the map entry, but upstream
cleared `texture_id_` *outside* `textures_mutex_`:

```cpp
registrar_->texture_registrar()->UnregisterTexture(texture_id_, [&, id = texture_id_]() {
    std::lock_guard<std::mutex> lock(textures_mutex_);
    textures_.erase(id);            // erased under the lock
});
texture_id_ = 0;                    // ... but cleared outside it
```

So a frame callback that takes the lock in that window sees a live
`texture_id_` whose entry is already gone, and

```cpp
return pixel_buffer_textures_.at(texture_id_).get();   // throws
```

throws `std::out_of_range` into engine-owned C++ on the raster thread. The
process dies with `0xC0000409` and no Dart-side log, because nothing on the
Dart side ever ran. There is a second instance of the same window between
`RegisterTexture` returning and the new entry being emplaced.

**The engine does have a handler — that correction matters, because it changes
where the fix has to go.** An earlier version of this file claimed the throw had
"no handler and is `std::terminate` by definition". The dump disagrees, and the
registers are decisive: `ecx = 7`, and `.exr -1` reports
`Subcode: 0x7 FAST_FAIL_FATAL_APP_EXIT`. The stack is

```
msvcp140!std::_Xout_of_range
media_kit_video_plugin!…            <- 50-byte function, throws
media_kit_video_plugin!…            <- its caller, 358 bytes
flutter_windows!…                   <- engine C++ that called into the plugin
  _CxxThrowException → RaiseException
  ntdll!RtlpExecuteHandlerForException   <- engine DID catch it
  int 29h / __fastfail(7)               <- and killed the process itself
```

So the engine catches the C++ exception and then deliberately terminates, rather
than unwinding into us — same observable outcome (dead process, no Dart log,
`0xC0000409`), different mechanism, and `0xC0000409` here is *not* a stack
buffer overflow despite the exception's name. Every function name in that trace
is a `dbghelp` guess: there is no Release PDB for the plugin or for
`flutter_windows.dll`, so the symboliser attributed the frames to whatever export
was textually nearest. Only the CRT frames and the module+offset pairs are real.

Observed on this repo as six identical WER minidumps during live zapping (each
one a `texture_id_` lookup that killed the player), all with the same stack:
`media_kit_video_plugin` → `std::_Xout_of_range` → `CxxThrowException` →
`flutter_windows` handler → `__fastfail(FAST_FAIL_FATAL_APP_EXIT)`.

Note what is *not* the cause: exceptions raised inside a `ThreadPool::Post`ed
task are captured by `std::packaged_task` into the task's future, which
`NotifyRender` discards. A throw there drops one frame silently. It cannot
terminate the process — which is why the fatal path is specifically the
engine-invoked callback, outside the pool.

## The patch (`windows/`)

1. **`video_output.cc` — both texture callbacks.** `at()` → `find()`, returning
   the `nullptr` that each callback already used for "no texture". This is the
   fix for the crash: a frame that finds nothing paints nothing, exactly as the
   existing `texture_id_ == 0` branch does.
2. **`video_output.cc` — `Resize`.** Clear `texture_id_` while holding
   `textures_mutex_`, so the ordering "entry gone ⇒ id is 0" holds for any
   reader that takes the lock.
3. **`video_output.cc` — `Render`, `CheckAndResize`.** Same non-throwing
   lookup, and return instead of proceeding when the texture is already gone.
   Upstream's throw here was swallowed by the discarded future, i.e. a silently
   dropped frame; make it explicit and bail early.
4. **`video_output.cc` — `NotifyRender`, `~VideoOutput`.** Guard the
   `ThreadPool::Post` calls. `Post` throws `std::runtime_error` once the pool is
   stopped, `NotifyRender` is called from mpv's render update callback (C code,
   no handler), and a throwing destructor is `std::terminate` by definition.
5. **`video_output.cc` — `~VideoOutput`.** Only `wait()` on the teardown
   promise when a texture existed. The promise is satisfied from that texture's
   release callback, so upstream's unconditional wait blocked forever for an
   output that never received one.
6. **`video_output.h` — `width()`/`height()`.** Non-throwing lookup; a `const`
   accessor must not throw during texture replacement.
7. **Whole-body `try`/`catch` on both texture callbacks**, and on
   `MediaKitVideoPlugin::HandleMethodCall`. Added *after* the `at()` → `find()`
   conversion, because those conversions were not enough — and because the
   dump's throwing frame could not be attributed to any line of ours. There is
   no `.at(` anywhere in this package, so the `std::out_of_range` came from an
   `.at()` inlined out of a header, not out of a `.cc`, and with no PDB there is
   no way to name it. The barrier therefore does not try to find the bug: it
   makes every boundary the engine calls into incapable of throwing past it,
   so the failure mode degrades from a killed process to a dropped frame. That
   is the only defence available when the throwing frame is unattributable, and
   it is what the engine's own handler would otherwise turn fatal.
   `HandleMethodCall` needs it most: its arguments arrive over the method channel
   rather than from our own code, and `std::get` on a mismatched
   `EncodableValue` or `std::stoll` on a non-numeric / oversized string throws
   (`std::bad_variant_access`, `std::invalid_argument`, and `std::out_of_range`
   — the last is literally the `std::_Xout_of_range` the dump names). The catch
   deliberately does not touch `result`, because several branches move it into a
   continuation and replying an error could use a moved-from `unique_ptr`.
7. **`thread_pool.h` — worker loop.** Catch around `task()`. `packaged_task`
   already captures exceptions from the callable; this covers the task
   machinery itself throwing, so no posted task can ever reach `terminate`.

## Known upstream hazard, deliberately not patched

If the engine never invokes a texture's release callback, `~VideoOutput` still
blocks on the teardown promise. Fixing that means letting the destructor return
while pool tasks may still reference `this`, which trades a hang for a
use-after-free. Not worth it; the hang is unreachable while creation always
yields a texture.

## Re-applying on a version bump

Copy the new version over this directory, re-apply the seven edits above (each is
marked in place), then re-point the `path:` in the app's `pubspec.yaml` and
confirm the rebuilt `media_kit_video_plugin.dll` sitting next to the runner at
`build/windows/x64/runner/Release/` is the new one.

**Set the file's mtime after copying.** A pub-cache file carries the download
date, so `Copy-Item` over an edited source gives the new file an *older* timestamp
than its object file, MSBuild concludes nothing changed, and the build succeeds
while shipping the previous DLL. The tell is a `media_kit_video_plugin.dll` whose
timestamp did not move. Same trap as `app.so`'s mtime being no freshness proof
(CLAUDE.md, "Verification gate") — and unlike `app.so`, here a stale mtime *does*
mean the binary is stale.

## Verifying a Windows change landed

`media_kit_video_plugin.dll` carries a PE `TimeDateStamp`, so hashing the whole
file differs between two builds of *identical* source and proves nothing. Hash
the `.text` section's bytes instead: two builds of this patched tree produce the
same `.text` hash, and the unpatched 2.0.1 source produces a different one
(92160 vs 92672 bytes here). `pe_sections.ps1` in the working scratch dir does it.