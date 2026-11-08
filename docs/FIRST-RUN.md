# Первый запуск: сначала CI, потом телефон

Проект ни разу не собирался на Windows (Swift там не встал), поэтому
первая компиляция — в CI. Порядок такой: пушим → смотрим, что сказал
GitHub Actions → правим → ставим на iPhone.

## 1. Загрузить репозиторий на GitHub

Локальный git-репозиторий уже создан (один коммит). Дальше:

```bash
git remote add origin https://github.com/<ваш-аккаунт>/max-client.git
git branch -M main
git push -u origin main
```

Репозиторий **приватный** — не столько из-за кода, сколько из-за
протокола и предупреждений о ToS.

## 2. Посмотреть сборку

Вкладка **Actions** → workflow **CI**. Две джобы:

- `Core (SwiftPM)` — ядро и офлайн-тесты протокола, минуты;
- `iOS build & tests` — `xcodegen generate`, сборка и тесты на симуляторе.

Первая сборка почти наверняка найдёт ошибки компиляции: проект писался
без компилятора. Типичные места:

| Симптом | Что смотреть |
|---|---|
| `cannot find type 'AvatarView'` / `Theme` | `MaxClient/Core/Design/Theme.swift` |
| `No such module 'GRDB'` | Packages → Resolve Package Versions |
| `Info.plist ... already exists` | `excludes` в `project.yml` |
| `value of type 'View' has no member ...` | iOS 16: проверить, что API есть в 16, а не 17+ |
| тесты падают в `RepositoryTests` | миграции разошлись с `Repositories.swift` |

Лог ошибок в Actions читается так же, как в Xcode: файл, строка, текст.
Правки — коммит → push → CI перезапускается сам.

## 3. Установка на iPhone

1. Скачать артефакт `MAX-unsigned-<sha>` из последнего успешного запуска
   (внутри — `.app` для устройства и `MAX-unsigned.ipa`).
2. Вариант А (с Mac): `open MaxClient.xcodeproj`, выбрать Team,
   ⌘R на подключённый телефон. Через 7 дней — снова ⌘R
   (или год, если аккаунт разработчика платный).
3. Вариант Б (без Mac): `MAX-unsigned.ipa` → Sideloadly / SideStore /
   AltStore, подпись вашим Apple ID на устройстве.
4. Вариант В (iOS 14.0–17.0): TrollStore — установка неподписанного
   IPA навсегда, без переподписи.

## 4. Проверка входа

1. Сплэш → экран номера телефона.
2. Номер → ожидаемо `VERIFICATION_REQUEST`: экран ввода кода.
3. Код из SMS → `CODE_ENTER` → `LOGIN` → список чатов.
4. Открыть чат: история (opcode 49), отправка (64) оптимистичная.
5. Свернуть/развернуть приложение: повторного `LOGIN` быть не должно.

## 5. Если протокол не отвечает

- Ничего не приходит → `MaxProtocol.wsURL`, версия кадра (`ver`).
- Ошибки `auth.*` → `MaxAuthService` (поля `token`, `codeLength`).
- Ответ есть, UI пуст → `MaxParser`, имена полей на сервере.
- Соединение рвётся через полминуты → интервал PING (20 с).

Живую проверку удобнее делать с Mac через CLI:

```bash
cd Tools/max-core
swift run max-core selftest   # офлайн
swift run max-core ping       # INIT к серверу
swift run max-core auth +79991234567
```

## 6. Ограничения (не баги сборки)

- Вложения только отображаются, загрузка файлов не реализована.
- 2FA (пароль на аккаунте) не поддерживается — будет сообщение.
- Push-уведомлений нет, `UIBackgroundModes` прописан на будущее.
- TCP/MessagePack включается в настройках и требует перезапуска.
