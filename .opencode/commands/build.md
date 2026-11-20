---
description: "Собрать iptvs (Windows по умолчанию; также android/linux)."
agent: iptvs-build
---
Собери iptvs. Аргументы: $ARGUMENTS

Собери **все переданные цели за один запуск** (`windows` по умолчанию, `android`, `linux`), не возвращаясь после первой. Если цели не указаны — уточни их. Следуй своим правилам: зависимости, `flutter analyze`/`test`, release-сборка, проверка `app.so`. Не редактируй исходники, не делай commit/push.
