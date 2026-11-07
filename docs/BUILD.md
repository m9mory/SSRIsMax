# Сборка

Три способа, от простого к самому контролируемому. Дальше по тексту —
что делать, когда сборка падает, и как получить приложение на устройство.

## 1. Xcode локально

```bash
brew install xcodegen        # один раз
xcodegen generate            # MaxClient.xcodeproj из project.yml
open MaxClient.xcodeproj     # ⌘R — симулятор или устройство
```

Схема `MaxClient` содержит тест-таргет `MaxCoreTests` (⌘U).
Проект (.xcodeproj) не хранится в репозитории: он целиком генерируется
из `project.yml`, поэтому новые файлы в `MaxClient/` подхватываются сами.

## 2. GitHub Actions

Workflow `.github/workflows/ci.yml` на каждый push/PR:

| Джоба | Что делает |
|---|---|
| `core` (SwiftPM) | собирает `Tools/max-core` и гоняет офлайн-тесты протокола |
| `ios` | проверяет зеркало ядра → `xcodegen generate` → сборка для симулятора → тесты → артефакты |

Артефакт запуска: `MAX-debug-<sha>` — не подписанные `.app` и
`MAX-unsigned.ipa`. Сертификаты и provisioning-профили в CI не нужны:
подпись — ваша, ниже.

Первый запуск удобно сделать кнопкой **Run workflow** на вкладке Actions.

## 3. Без XcodeGen

1. Xcode → File → New → Project → iOS App (SwiftUI, язык Swift).
2. Удалить `ContentView.swift` и `*App.swift`, перетащить папку `MaxClient/`
   в навигатор (Create groups, target MaxClient).
3. File → Add Package Dependencies… → `https://github.com/groue/GRDB.swift`,
   Up to Next Major Version 6.29.0.
4. Build Settings → Info.plist File = `MaxClient/Resources/Info.plist`,
   Localization Native Development Region = `ru`.
5. Signing & Capabilities → выбрать Team.

## Как поставить приложение на iPhone

Варианты по убыванию удобства:

**Xcode + бесплатный Apple ID.** ⌘R на подключённый iPhone. Приложение
работает 7 дней, потом подпись истекает — снова ⌘R.

**Xcode + платный аккаунт разработчика ($99/год).** Тот же ⌘R, без
ограничения в 7 дней; годовая переподпись.

**SideStore / AltStore / Sideloadly (бесплатно, без Mac под рукой).**
Приложение подписывается на устройстве вашим Apple ID. Берём
`MAX-unsigned.ipa` из артефакта CI и перетаскиваем в Sideloadly.
Ограничения те же: 7 дней, не больше трёх приложений.

**TrollStore (iOS 14.0–17.0).** Подпись не нужна вообще — установка
неподписанного IPA постоянная.

Подписанный IPA CI выдать не может: Apple не отдаёт сертификат без вашего
аккаунта, а приватные ключи в GitHub Secrets — плохая идея для проекта,
который вы держите открытым.

## Если сборка падает

| Симптом | Причина и что делать |
|---|---|
| `cannot find type 'AvatarView'` | не сгенерирован проект: снова `xcodegen generate` |
| `No such module 'GRDB'` | не подтянулся пакет — File → Packages → Resolve Package Versions |
| `Info.plist ... already exists` | в bundle попал второй Info.plist: проверьте `excludes` в `project.yml` |
| `simctl` не находит устройство | на раннере сменилось имя iPhone — используйте выбор по UDID из workflow |
| `Unable to boot simulator` | повторить запуск; на macOS-раннере симуляторы иногда заняты |
| Тесты падают в `RepositoryTests` | миграции разошлись с `Repositories.swift` |

## Тесты

- **`core`** (SwiftPM, `Tools/max-core/core-kit`) — протокол без iOS:
  MessagePack, JSON/бинарные кадры, парсеры, события.
- **`MaxCoreTests`** (XCTest в Xcode/CI) — то же плюс форматирование
  телефона и локальная база GRDB в памяти.

Правки ядра в `MaxClient/Core` нужно переносить в зеркало:
`scripts/sync-core.sh` (macOS) или `scripts/sync-core.ps1` (Windows).
CI проверяет это шагом «Зеркало ядра не отстало».
