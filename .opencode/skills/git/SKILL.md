---
name: git
description: "Git iptvs: ветка local, remotes origin/upstream, LFS для Android, правила коммита. Use when committing, pushing or inspecting git history in iptvs."
---

# Git — iptvs

Репозиторий: `C:\Users\SERGEYBO\Documents\Projects\iptvs`.

## Remotes и ветка

- `origin` = https://github.com/SNBogdanov/iptvs.git (форк).
- `upstream` = https://github.com/GCHOfficial/iptvs.git.
- Рабочая ветка: `local` (upstream `origin/local`). Проверяй:
  `git branch --show-current`, `git rev-parse --abbrev-ref --symbolic-full-name @{u}`.

## Жёсткие правила

- Коммит и пуш — только по явной просьбе и только через субагент `git-commit`
  (команда `/commit`). Main-сессия не делает `git add/commit/push` сама.
- Перед коммитом: `git status --short`, `git diff`, `git log --oneline -10`.
- Не делать force, amend, `--no-verify`; не менять git config.
- Не коммитить секреты (`dart_define.json` с ключами, keystore/пароли) и
  артефакты: `build/`, `.dart_tool/`, `*.apk`, `*.exe`, логи.

## Git LFS

- Android-сборка требует LFS: `git lfs install && git lfs pull`.
- Не коммить LFS-объекты напрямую; `android/app/libs/libmpv-dovi.aar` идёт через LFS.

## Push

- Push — только в текущую ветку/upstream, без force.
- При отказе (non-fast-forward, auth, VPN) — не force, сообщи причину и что
  осталось.

## Сообщения коммитов

- Кратко, в стиле последних коммитов (`git log --oneline -10`); тело — только
  «почему», без пересказа диффа.
