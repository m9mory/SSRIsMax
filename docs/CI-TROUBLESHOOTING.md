# GitHub Actions не запускается: что искать

Симптом: workflow есть, но каждый push создаёт «упавший» запуск длиной
в ноль секунд, `conclusion: failure`, в `jobs` — пустой список
(`total_count: 0`). Джобы даже не создаются.

Это не ошибка YAML и не ошибка кода. Причины, от самой частой:

## 1. Не включён биллинг / лимит раннеров

Settings → Billing and plans → Plans and usage. Для приватного
репозитория macOS-раннер тратит минуты из квоты (macOS ×10 к умножению:
1 минута = 10 минут квоты). Если квота нулевая или карта не привязана,
запуск падает сразу.

Проверка бесплатно: сделать репозиторий публичным (Settings → General →
Danger Zone → Change visibility). Публичные репозитории собираются
на macOS-раннерах без квоты.

## 2. Actions ограничены на уровне организации

Для личных аккаунтов: Settings → Actions → General → «Allow all actions
and reusable workflows». Если выбран ограниченный режим, `actions/cache`
и `actions/upload-artifact` (запросы к `github.com`) могут блокироваться.

## 3. Ограничения аккаунта

Новая учётная запись без подтверждённого e-mail или с флагом на
бесплатные минуты — Actions отключается молча. Проверить:
github.com/settings/billing (статус аккаунта) и почту на письма
от GitHub.

## 4. Что проверить прямо на странице запуска

Actions → нужный run. Если видно «The job was not started because…» —
текст подскажет причину. Кнопка **Re-run jobs** иногда помогает, если
это была временная проблема.

## Пока Actions не работает

Локальная проверка покрывает почти всё, что делает CI:

```bash
brew install xcodegen
xcodegen generate
xcodebuild -project MaxClient.xcodeproj -scheme MaxClient \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

Собранное приложение — в `~/Library/Developer/Xcode/DerivedData/…/Build/Products/`,
дальше `scripts/make-ipa.sh <App.app> MAX-unsigned.ipa`.

Вернуть CI можно и позже: сам workflow уже в репозитории, от него
понадобится только «Run workflow» на вкладке Actions.
