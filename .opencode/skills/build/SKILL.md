---
name: build
description: "Сборка iptvs (Flutter): Windows/Android/Linux, pub get, analyze, test, release и проверка app.so. Use when building the iptvs app."
---

# Сборка iptvs

Проект: `C:\Users\SERGEYBO\Documents\Projects\iptvs`.
Перед сборкой прочитай `README.md`, `CLAUDE.md` (разделы «Commands» и
«Verification gate») и профильный `docs/*.md`.

## Правила

- Собери **все** переданные цели за один запуск (`windows` по умолчанию,
  `android`, `linux`); не возвращай управление после первой.
- Если цели не переданы — уточни их и подтверди полную сборку.
- Не редактируй исходники и не делай commit/push.
- Android требует Git LFS: `git lfs install && git lfs pull` — иначе
  `android/app/libs/libmpv-dovi.aar` не слинкуется.
- CI пин — Flutter 3.44.5; установленный SDK может быть новее — проверяй
  `flutter --version`, но пин не меняй.
- Windows: запущенная **установленная** копия `iptvs.exe` не блокирует сборку в
  `build\...\Release` — не убивай её. Если заблокирован сам Release-exe
  (запущен из Release), сообщи и не убивай процесс без согласия.
- **Никогда не убивай процессы по имени образа** (`taskkill /IM iptvs.exe`,
  `Stop-Process -Name iptvs`): на машине может быть запущено установленное
  приложение пользователя. Если нужно снять именно свой процесс — только по PID,
  который ты сам запустил, или по пути внутри `build\...`.

## Два режима проверки

**Итерационная сборка — по умолчанию.** Пользователь ждёт артефакт, а не
релизный гейт:

```powershell
flutter pub get
flutter analyze
flutter test test/<затронутые области>_test.dart   # профильные, не весь набор
flutter build <цель> --release --no-pub
```

Профильные тесты выбирай по изменению: плеер — `player_overlay_test`,
`media_*`; база/миграции — `persistence_test`, `released_schema_fixtures_test`;
облако — `cloud_*`, `watch_state_test`; прокси — `proxy_config_test`. Если
изменение общее (ядро, `AppDatabase`, `main.dart`), возьми более широкий набор,
но не весь `test/`.

**Релизная сборка — только когда в задании явно сказано «релиз» / «перед
релизом».** Полный `flutter test` (~30 минут, отдельный процесс и отдельный
PID), затем артефакты:

```powershell
flutter pub get
flutter analyze
flutter test
flutter build <цель> --release --no-pub
```

Полный набор обязателен перед тегом/релизом и перед коммитом, который трогает
общий код. В отчёте для релизной сборки — число passed/skipped и **все**
падения (даже известные env-флейки называй явно).

**Лок — одна команда на всю сборку** (включая долгий `flutter test`):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\Users\SERGEYBO\.config\opencode\bin\build-lock.ps1 run -Project iptvs -Kind <вид> -CommandLine "<вся цепочка команд>"
```

`run` держит лок, пока команда не завершится, и снимает его сам; `exit 2` —
занято, тогда не собирай. Не определяй «просроченность» лока по PID — только по
возрасту, и снимает её скрипт.

## Сборка

```powershell
flutter pub get
flutter analyze
# тесты — по режиму выше (профильные / полный)
# Windows
flutter build windows --release --no-pub
# Android
flutter build apk --release
# Linux
flutter build linux --release
```

**Не используй `--no-pub` для первого Android-билда после debug-сборки.** `flutter
build` под `--no-pub` не перегенерирует `android/app/src/main/java/io/flutter/plugins/
GeneratedPluginRegistrant.java`, а тот, оставленный debug-сборкой, регистрирует
`integration_test` (dev-dependency) — release компилируется без него и падает на
`package dev.flutter.plugins.integration_test does not exist`. Лечится `flutter pub get`
между сменой режима сборки (или просто сборкой без `--no-pub`).

## Локальная сборка: облачный конфиг (Windows и Android)

Ключевое, что легко потерять: **Supabase-конфиг приходит только через
`--dart-define`**. Без него `CloudConfig.isConfigured == false`, и в приложении
пропадают облачный профиль (на старте остаются только локальные), синхронизация
избранного и watch-state. Сборка при этом успешна — просто без облака.

Поэтому **любая локальная сборка для установки пользователю** (Windows, Android)
должна повторять CI (`build.yml`):

```powershell
# Windows
flutter build windows --release `
  --dart-define-from-file=dart_define.json `
  --dart-define=DISTRIBUTION_CHANNEL=development

# Android (debug, dev-пакет)
flutter build apk --debug --flavor development `
  --dart-define-from-file=dart_define.android.json `
  --dart-define=DISTRIBUTION_CHANNEL=development
```

`dart_define.json` / `dart_define.android.json` — gitignored, лежат в корне
репозитория; содержат `SUPABASE_URL`, `SUPABASE_ANON_KEY` и локальный
`PANEL_URL`. Если файла нет — **не собирай молча без облака**: сообщи, что
облачные функции будут недоступны, и спроси, нужен ли такой артефакт.

`DISTRIBUTION_CHANNEL` по умолчанию и так `development`, но передавай явно —
на нём завязаны обновления и подпись канала.

Release-сборка для установки на телефон — `--flavor githubDirect` (пакет
`.direct`, подпись ключом форка `secrets/iptvs-release.jks`), а не `development`:
это разные applicationId, и обновить существующую установку «поверх» ими нельзя.
Флейвора `googlePlay` в форке больше нет — магазины не используются.

## Правило релиза (версия и подпись)

- «Сборка release» = поднять `version:` в `pubspec.yaml` на 1 patch, собрать релиз после полного
  `flutter test` и выложить на GitHub (коммит, тег `v<версия>`, push). Итерационная сборка версию
  **не** поднимает.
- `versionCode` считается из имени версии (`versionCodeFromName`), поэтому релиз всегда выше
  предыдущего; `--build-number` и `--split-per-abi` не использовать.
- До следующего релиза все сборки идут с этой версией и **release-подписью**, включая debug:
  на телефон **Note** ставится `--debug --flavor githubDirect` (пакет `.direct`) через
  `adb install -r` поверх предыдущей установки — одна копия приложения, без второго ярлыка.

Артефакты:

- Windows: `build\windows\x64\runner\Release\` (проверяй `data\app.so`).
- Android: `build\app\outputs\flutter-apk\`.
- Linux: `build\linux\x64\release\bundle\`.

## Verification gate (Windows)

`app.so` — единственный признак свежести Dart-кода; mtime не доказательство.
Flutter кеширует AOT по содержимому и сохраняет исходный mtime, поэтому:

- сверь SHA-256 `build\windows\x64\runner\Release\data\app.so` с content-keyed
  AOT в `.dart_tool\flutter_build\*\app.so`;
- при совпадении хэшей артефакт свежий (`FRESH OK`), даже если mtime старый;
- **никогда не удаляй `iptvs.exe`**, чтобы «форсировать» сборку;
- `flutter test` доказывает логику, но не артефакт, который запускает пользователь.

## MSIX / Store

Только по просьбе: `tool\package_windows_msix.ps1`, см. `docs/updates.md` (подпись MSIX).

## Отчёт

Цель, выполненные команды, путь артефакта, результат `analyze`/`test` (включая
skipped), предупреждения. При падении — ключевые ошибки, не весь лог.
