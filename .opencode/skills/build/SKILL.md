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
  `flutter --version`, но пин не меняй. CI ожидает чистый `flutter analyze` и
  зелёный `flutter test`.
- Windows: запущенная **установленная** копия `iptvs.exe` не блокирует сборку в
  `build\...\Release` — не убивай её. Если заблокирован сам Release-exe
  (запущен из Release), сообщи и не убивай процесс без согласия.

## Сборка

```powershell
flutter pub get
flutter analyze
flutter test
# Windows
flutter build windows --release --no-pub
# Android
flutter build apk --release
# Linux
flutter build linux --release
```

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

Только по просьбе: `tool\package_windows_msix.ps1`, см. `docs/store-publishing.md`.

## Отчёт

Цель, выполненные команды, путь артефакта, результат `analyze`/`test` (включая
skipped), предупреждения. При падении — ключевые ошибки, не весь лог.
