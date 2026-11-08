# GitHub Actions: разбор проблем

## "Invalid workflow file" на строке N

Главная причина, на которой мы уже наступили: **внутри блока `run: |`
нельзя резко уменьшать отступ**. Если в shell-скрипте есть строка с
отступом 0 (например, heredoc или многострочный python, вставленный
«как есть»), YAML считает, что блок `run` закончился, и разбирает
остаток как новые ключи — отсюда жалоба на строку внутри скрипта.

Правило: все строки `run: |` должны начинаться с одного и того же
отступа (`run:` + 2 пробела), а всё содержимое — с большего.

Проверка локально, без GitHub:

```bash
# строки с нулевым отступом — только ключи верхнего уровня
grep -n '^[^ #]' .github/workflows/ci.yml
```

Должно вывести ровно `name:`, `on:`, `concurrency:`, `env:`, `jobs:`.

Вторая причина того же сообщения: табы вместо пробелов (`\t`),
незакрытая кавычка, или `${{ }}` внутри `run`, где имя не определено.

## Запуск падает за 0 секунд, джоб нет

Симптом: запуск создан и сразу `failure`, `jobs` пустой, `created_at`
совпадает с `updated_at`. Причины, от самой частой:

### 1. Не включён биллинг / лимит раннеров

Settings → Billing and plans → Plans and usage. Для приватного
репозитория macOS-раннер тратит минуты из квоты с коэффициентом ×10.
Если квота нулевая или карта не привязана, запуск падает сразу.

Бесплатная проверка: сделать репозиторий публичным (Settings → General →
Danger Zone → Change visibility). Публичные репозитории собираются
на macOS-раннерах без квоты.

### 2. Actions ограничены на уровне организации

Settings → Actions → General → «Allow all actions and reusable workflows».
Ограниченный режим блокирует `actions/checkout`, `actions/cache`,
`actions/upload-artifact`.

### 3. Ограничения аккаунта

Неподтверждённый e-mail или флаг на бесплатные минуты у нового аккаунта —
Actions отключаются молча. Проверить почту на письма от GitHub.

## Пока Actions не работает

```bash
brew install xcodegen
xcodegen generate
xcodebuild -project MaxClient.xcodeproj -scheme MaxClient \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

Для `.ipa` нужна сборка под устройство, а не под симулятор:

```bash
xcodebuild -project MaxClient.xcodeproj -scheme MaxClient \
  -configuration Release -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  -derivedDataPath build-device build
```

Дальше `scripts/make-ipa.sh <путь к MAX.app> MAX-unsigned.ipa`.
Скрипт принимает и относительные пути: он делает их абсолютными сам,
до перехода во временный каталог.

