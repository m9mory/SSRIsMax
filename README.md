# MAX — клиент мессенджера на SwiftUI

Неофициальный клиент мессенджера **MAX** для iOS. Написан с нуля на SwiftUI:
свой протокол клиента MAX (`api.oneme.ru`), свой MessagePack-кодек, свой слой
хранения и сетевого транспорта. Внешних зависимостей — одна (GRDB).

> ⚠️ Проект не связан с VK/MAX. Он работает по недокументированному протоколу
> мобильного клиента; сервер может изменить его в любой момент, а использование
> сторонних клиентов может нарушать условия сервиса. Пробуйте на своём аккаунте.

## Что внутри

```
MaxClient/
├── App/                      точка входа, корневой роутинг, splash
├── Core/
│   ├── Protocol/             MessagePack-кодек, кадры, opcodes, парсеры ответов
│   ├── Network/              WebSocket (JSON) и TCP/TLS (MessagePack) транспорты, MaxClient-актор
│   ├── Auth/                 вход по SMS-коду, INIT/VERIFICATION_REQUEST/CODE_ENTER/LOGIN
│   ├── Storage/              GRDB: миграции, репозитории, Keychain
│   ├── Models/               доменные модели (Int64 id, String messageId)
│   ├── Design/               тема, аватары, форматирование, телефон
│   └── Session.swift         @MainActor-состояние приложения и сценарии
├── Features/
│   ├── Auth/                 ввод телефона и кода
│   ├── Chats/                список чатов, переписка
│   ├── Main/                 табы
│   └── Settings/             профиль, настройки, «о приложении»
└── Resources/                Info.plist, Assets.xcassets (иконка, цвет запуска)

Tests/CoreTests.swift         XCTest: кодек, кадры, парсеры, репозитории
Tools/max-core/               SwiftPM-CLI для проверки протокола без iPhone
docs/                         заметки по протоколу, сборке, миграциям
scripts/sync-core.ps1|.sh     копирование ядра в CLI-пакет
project.yml                   спецификация XcodeGen
```

## Сборка

```bash
brew install xcodegen        # если ещё нет
xcodegen generate
open MaxClient.xcodeproj     # ⌘R — на устройство или симулятор
```

Минимум — iOS 16. Подпись: выберите Team в Signing & Capabilities.
Сборку без XcodeGen и запуск тестов (⌘U) см. в [docs/BUILD.md](docs/BUILD.md).

## Как устроено

**Транспорт.** По умолчанию — WebSocket (`wss://ws-api.oneme.ru/websocket`,
кадры JSON, `ver = 11`): его видно в отладчике и легко логировать. В настройках
можно переключиться на TCP/TLS (`api.oneme.ru:443`, MessagePack, `ver = 10`) —
это то, чем пользуются официальные мобильные клиенты. Требуется перезапуск.

**Кадры.** `MaxFrame {ver, cmd, seq, opcode, payload}`; `cmd`: 0 — запрос или
push, 1 — ACK, 3 — ошибка. Соответствие запрос/ответ — по `seq`
(`MaxFramePump`), у каждого запроса свой таймаут; отмена не «съедает» чужой
ответ.

**Ping.** Сервер ждёт `opcode 1` каждые ~20 секунд, иначе рвёт соединение.
Пингуется и на прикладном уровне, и в ответ на серверный ping-push.

**Переподключение.** Экспоненциальная пауза, до 6 попыток, повторное
`LOGIN` уже имеющимся токеном. `LOGIN` с новым токеном «сжигает» старый,
поэтому в сессии живёт ровно одно соединение.

**Хранение.** GRDB/SQLite: `chat`, `message`, `user` + FTS5-индекс
`message_search` с триггерами. Список чатов рисуется из базы (мгновенно и
офлайн), сеть его дополняет. Отправка оптимистичная: сообщение сразу
появляется с временным id `local-…` и заменяется серверным после `MSG_SEND`.

**Секреты.** Токен, `deviceId` и id пользователя — в Keychain
(`KeychainCredentialStore`), настройки — в UserDefaults.

**Вход.** `INIT` → `VERIFICATION_REQUEST` (SMS) → `CODE_ENTER` → `LOGIN`.
Двухфакторный вход (пароль) сознательно не поддерживается: сервер вернёт
`twoFactorRequired`, пользователь увидит понятное сообщение.

## CLI для проверки протокола

`Tools/max-core` — отдельный SwiftPM-пакет, в который скрипт копирует
те же файлы ядра (без SwiftUI/UIKit/GRDB). Удобно отлаживать протокол
в терминале, не пересобирая приложение:

```bash
cd Tools/max-core
swift run max-core selftest      # кодек, кадры, парсеры — без сети
swift run max-core ping          # реальный INIT к ws-api.oneme.ru
swift run max-core auth +79991234567
```

После правок в `MaxClient/Core` запустите `scripts/sync-core.ps1` (Windows) или
`scripts/sync-core.sh` (macOS), иначе CLI останется на старой копии.

## Документация

- [docs/FIRST-RUN.md](docs/FIRST-RUN.md) — чек-лист первой сборки и запуска
- [docs/PROTOCOL-NOTES.md](docs/PROTOCOL-NOTES.md) — opcodes, ловушки протокола
- [docs/BUILD.md](docs/BUILD.md) — сборка, тесты, ручная настройка проекта
- [docs/MIGRATIONS.md](docs/MIGRATIONS.md) — правила изменения схемы базы

## Источник протокола

Описание протокола собрано сообществом:
[pr0bel1230/max-api-docs](https://github.com/pr0bel1230/max-api-docs)
(CC BY 4.0). Спасибо авторам — без этой документации клиент был бы невозможен.

## Что не сделано

- Загрузка и отправка вложений (`PHOTO`/`FILE`/`VIDEO`) — только отображение.
- Поиск по серверу, контакты по номеру телефона, звонки, стикеры.
- Push-уведомления (нужен APNs-сертификат и поддержка на стороне сервера).
- Шифрование локальной базы (`SQLCipher`).
