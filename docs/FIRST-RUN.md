# Чек-лист первого запуска

Проект ни разу не собирался на Windows (Swift toolchain там не встал),
поэтому ниже — что проверить на Mac по порядку. Так ошибки находятся
по одной, а не все сразу.

## 1. Генерация и компиляция

```bash
brew install xcodegen
xcodegen generate
open MaxClient.xcodeproj
```

Сборка (⌘B). Ожидаемые места, где может потребоваться правка:

| Симптом | Что смотреть |
|---|---|
| `cannot find type 'AvatarView'` / `Theme` | `Core/Design/Theme.swift` |
| ошибки GRDB `no such module` | Packages → GRDB не подтянулся, дождитесь загрузки |
| `Info.plist ... already exists` | `project.yml`: `excludes` для `Resources/Info.plist` |
| `Cannot find 'ContentUnavailableView'` | целевая версия iOS < 17 в этом файле; заменить на `VStack` |

`ContentUnavailableView` появился в iOS 17 — если деплой-таргет остаётся 16,
эти два места (`ChatListView`, `ContactsPlaceholderView`) нужно заменить на
обычные `VStack` с иконкой и текстом.

## 2. Тесты

⌘U. Должны пройти 13 тестов: кодек, кадры, парсеры, телефон, репозитории.
Падение в `RepositoryTests` = рассинхрон миграций и `Repositories.swift`.

## 3. Запуск

1. Signing & Capabilities → выбрать Team.
2. Запустить на симуляторе: сплэш → экран ввода номера.
3. Ввести реальный номер: должен открыться экран кода, в консоли —
   `INIT ok`, затем `VERIFICATION_REQUEST`.
4. Код из SMS → `CODE_ENTER` → `LOGIN` → список чатов.
5. Открыть чат: история подгружается (opcode 49), отправка (64) оптимистичная.
6. Свернуть/развернуть приложение: соединение не должно «сгорать»
   (в логах нет повторного `LOGIN`).

## 4. Если не работает

- Ничего не приходит вообще → проверить `MaxProtocol.wsURL` и версию кадра.
- `auth.*` ошибки → `MaxAuthService`, поля `token`, `codeLength`.
- Пришёл ответ, но UI пуст → `MaxParser` (имена полей сервера меняются).
- Быстрый разрыв соединения → интервал PING (сейчас 20 с).

Логи: `print` в `MaxClient`/`MaxSession` видно в Xcode-консоли;
для живого протокола удобнее CLI:

```bash
cd Tools/max-core
swift run max-core ping
swift run max-core auth +79991234567
```

## 5. Известные ограничения (не баги сборки)

- Вложения только отображаются, отправка файлов не реализована.
- 2FA (пароль на аккаунте) не поддерживается — покажется сообщение.
- Push-уведомления нет, `UIBackgroundModes` уже прописан на будущее.
- Транспорт TCP/MessagePack переключается в настройках и требует
  перезапуска приложения.
