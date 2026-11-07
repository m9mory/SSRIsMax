# Заметки по протоколу MAX

Источник: [pr0bel1230/max-api-docs](https://github.com/pr0bel1230/max-api-docs) (CC BY 4.0),
исследования трафика, плюс собственные наблюдения при разработке этого клиента.

## Транспорты

| Транспорт | Адрес | Формат | ver |
|-----------|-------|--------|-----|
| WebSocket | `wss://ws-api.oneme.ru/websocket` | JSON-текст | 11 |
| TCP/TLS | `api.oneme.ru:443` | MessagePack | 10 |

Кадр: `{ver, cmd, seq, opcode, payload}`.

- `cmd = 0` — запрос клиента **и** push от сервера,
- `cmd = 1` — успешный ответ (ACK),
- `cmd = 3` — ошибка, в payload есть `error` и `message`.

Ответы сопоставляются с запросами по `seq`. Push приходит без `seq`.

## Обязательный старт сессии

1. **INIT (6)** — `{deviceId, userAgent}`.
2. **LOGIN (19)** — `{token, interactive, chatsCount, chatsSync, ...}`.

Без них любой другой опкод вернёт ошибку. LOGIN сжигает токен после
~30–50 повторных логинов за короткое время — поэтому держим **одно**
соединение и переподключаемся, а не производим новый логин на каждый запрос.

## Авторизация по SMS

```
CAPTCHA_REQUEST(224)  →  VERIFICATION_REQUEST(17)  →  код  →  CODE_ENTER(18)  →  LOGIN(19)
```

- `17` возвращает `{token, codeLength, requestMaxDuration, requestCountLeft}`;
- `18` возвращает `{tokenAttrs: {LOGIN: {token}}}`;
- ошибки: `auth.invalid.code`, `auth.blocked`, `track.not.found`.

## Опкоды, которые использует этот клиент

| Опкод | Название | Назначение |
|-------|----------|------------|
| 6 | INIT | старт сессии |
| 17/18 | VERIFICATION_REQUEST / CODE_ENTER | вход по SMS |
| 19 | LOGIN | токен → профиль + чаты |
| 49 | GET_HISTORY | история (`from` обязателен для `backward`) |
| 50 | CHAT_READ | отметка о прочтении |
| 53 | GET_CHATS | список чатов (`marker` — timestamp мс) |
| 61 | GET_CHAT_INFO | полный объект чата |
| 64 | MSG_SEND | отправка |
| 65 | MSG_TYPING | «печатает» |
| 66 | MSG_DELETE | удаление |
| 67 | MSG_EDIT | редактирование |
| 75 | CHAT_SUBSCRIBE | подписка на события чата |
| 92 | CHAT_ACTIVITY | активность (ставит watermark!) |
| 178/179 | REACT_SET / REACT_REMOVE | реакции |

Push (сервер → клиент): `1` ping, `129` печатает, `130` прочитано,
`132` присутствие, `136` файл загружен, `142`/`140` удаление,
`156` реакция.

## Подводные камни

**Идентификаторы — 64-битные.** `chatId` вида `-69110159553957`,
`messageId` вида `116762203424780659`. В JSON они приходят то числом,
то строкой, в MessagePack — через extension-тип 1. В клиенте везде
`Int64`, а для `messageId` — строка (для стабильных ключей БД).

**MSG_DELETE (66) с `forMe: false` после CHAT_ACTIVITY (92)** сносит
всё до watermark. В этом клиенте удаление по умолчанию только `forMe: true`.

**GET_HISTORY без `from` с `backward > 0`** возвращает пусто.
Всегда передаём `from` (текущее время или timestamp самого старого сообщения).

**elements[] не возвращается** в ответе на MSG_SEND и MSG_EDIT —
только в истории и push. Поэтому форматирование появляется после
перезагрузки истории.

**CHAT_SUBSCRIBE обязательна**, иначе не приходят 128/129/156 и
входящие звонки (137).

**PING (1)** — раз в ~15–20 с, иначе сервер закроет соединение через
30–60 с простоя. Отправка push-опкодов (128–156, кроме 144/145) как
запроса закрывает WebSocket.

**Медиа** — отдельная двухэтапная схема: `IMAGE_UPLOAD_URL(80)` /
`FILE_UPLOAD(87)` → HTTP-загрузка → push `NOTIF_ATTACH(136)` → MSG_SEND
с `attaches[]`. Аудио — opcode 82 (`{count, type: 2, uploaderType: 1}`),
поле `videoId` в ответе используется как `audioId`, `wave` — 80 сырых байт.

## Где чинить, если сервер изменился

1. `Core/Protocol/MaxProtocol.swift` — опкоды и версии клиента.
2. `Core/Protocol/MaxParser.swift` — разбор ответов (новые поля, типы).
3. `Core/Network/MaxTransport.swift` — маппинг push-событий.

Проверять после правок:

```bash
cd Tools/max-core
swift run max-core selftest   # офлайн-проверки кодека и парсеров
swift run max-core ping       # INIT к живому серверу
swift run max-core auth +79991234567
```

CLI собирается из тех же исходников, что и приложение
(в `Tools/max-core/Core` их копирует `scripts/sync-core.*`), поэтому
проверка в терминале отражает поведение клиента на телефоне.

