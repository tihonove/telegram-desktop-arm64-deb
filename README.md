# telegram-desktop-arm64-deb

apt-репозиторий с Telegram Desktop для **arm64** (aarch64) под Ubuntu 26.04.

Это **неофициальная перепаковка** официальной arm64-сборки Telegram Desktop.
Telegram публикует Linux arm64 только в snap-сторе: тарбола на сайте и пакета в
apt нет. Здесь GitHub Actions раз в сутки смотрит stable-канал стора, скачивает
snap, перекладывает его содержимое в `.deb` и публикует подписанный
apt-репозиторий. Бинарь не пересобирается и не изменяется. snapd не нужен.

Telegram Desktop распространяется под
[GPLv3 с исключением для OpenSSL](https://github.com/telegramdesktop/tdesktop/blob/master/LEGAL),
исходники — в [telegramdesktop/tdesktop](https://github.com/telegramdesktop/tdesktop).
Проект не связан с Telegram и им не поддерживается.

## Подключение

```sh
sudo install -d -m 755 /etc/apt/keyrings
sudo curl -fsSL -o /etc/apt/keyrings/telegram-desktop-arm64.asc \
  https://github.com/tihonove/telegram-desktop-arm64-deb/releases/download/repo/telegram-desktop-arm64.asc
echo "deb [signed-by=/etc/apt/keyrings/telegram-desktop-arm64.asc] https://github.com/tihonove/telegram-desktop-arm64-deb/releases/download/repo ./" \
  | sudo tee /etc/apt/sources.list.d/telegram-desktop-arm64.list
sudo apt update
sudo apt install telegram-desktop-arm64
```

Дальше обновления приходят обычным `apt upgrade`.

Что ставит пакет:

| Путь | Что там |
| --- | --- |
| `/opt/telegram-desktop/app` | содержимое snap как есть |
| `/opt/telegram-desktop/libs` | библиотеки, которых нет в Ubuntu 26.04 (ICU 74, ffmpeg 6 и их зависимости) |
| `/usr/bin/telegram-desktop` | скрипт запуска: добавляет в `LD_LIBRARY_PATH` только `libs` |
| `/usr/share/applications/org.telegram.desktop.desktop` | ярлык и обработчики `tg://`, `tonsite://` |
| `/usr/share/icons/hicolor/…/org.telegram.desktop*` | иконки, включая монохромные для трея |
| `/usr/share/doc/telegram-desktop-arm64/bundled-libs.txt` | откуда взята каждая забандленная библиотека |

Данные и сессия лежат в `~/.local/share/TelegramDesktop`, пакет их не трогает.

## Откат

В репозитории лежат три последние версии, остальные — в релизах `v<версия>`.

```sh
apt list -a telegram-desktop-arm64                 # какие версии доступны
sudo apt install telegram-desktop-arm64=7.2.9-1    # поставить конкретную
sudo apt-mark hold telegram-desktop-arm64          # не обновлять, пока не снят hold
sudo apt-mark unhold telegram-desktop-arm64
```

Версии, которой уже нет в репозитории, ставятся из релиза:
скачать `.deb` со страницы `v<версия>` и `sudo apt install ./telegram-desktop-arm64_<версия>_arm64.deb`.

Убрать совсем:

```sh
sudo apt purge telegram-desktop-arm64
sudo rm /etc/apt/sources.list.d/telegram-desktop-arm64.list /etc/apt/keyrings/telegram-desktop-arm64.asc
```

## Переход с ручной установки

Если Telegram уже распакован из snap руками в `~/.local/opt/telegram`:

1. Закрыть Telegram (в меню трея «Quit», не просто закрыть окно).
2. Убрать старую установку с дороги, пока не удаляя. `~/.local/bin` стоит в
   `PATH` раньше `/usr/bin`, поэтому старый скрипт запуска иначе перекроет новый:

   ```sh
   mv ~/.local/opt/telegram ~/.local/opt/telegram.manual-backup
   mv ~/.local/bin/telegram-desktop ~/.local/bin/telegram-desktop.manual-backup
   mv ~/.local/share/applications/org.telegram.desktop.desktop{,.manual-backup}
   ```

3. Подключить репозиторий и поставить пакет (см. выше).
4. Запустить `telegram-desktop`. Сессия подхватится из `~/.local/share/TelegramDesktop`.
5. Убедившись, что всё работает, удалить остатки:

   ```sh
   rm -rf ~/.local/opt/telegram.manual-backup
   rm -f ~/.local/bin/telegram-desktop.manual-backup
   rm -f ~/.local/share/applications/org.telegram.desktop.desktop.manual-backup
   rm -f ~/.local/share/icons/hicolor/symbolic/apps/org.telegram.desktop*-symbolic.svg
   ```

## Как это устроено

`build.sh` делает одно и то же локально и в CI:

1. Узнаёт у API snap-стора stable-ревизию для arm64, скачивает snap, сверяет
   sha3-384 и распаковывает его через `unsquashfs`.
2. Поднимает два контейнера: `ubuntu:26.04` (целевая система) и `ubuntu:24.04`
   (на этой базе, `core24`, собран snap).
3. Гоняет `ldd` в контейнере 26.04 и для каждой ненайденной библиотеки по
   очереди пробует:
   - пакет из репозиториев 26.04 — тогда библиотека уходит в `Depends`;
   - файл из самого snap;
   - `.deb` из 24.04 с ports.ubuntu.com — тогда библиотека кладётся в `libs`.

   Цикл повторяется, пока `not found` не кончатся: так подтягиваются и
   транзитивные зависимости. Список нигде не захардкожен и переживёт смену
   базы snap (достаточно поменять `DONOR_IMAGE`).
4. `Depends` — пакеты 26.04, из которых резолвятся прямые зависимости бинаря и
   забандленных библиотек. `Recommends` и `Suggests` — то, что Telegram грузит
   через `dlopen` ([packaging/recommends](packaging/recommends),
   [packaging/suggests](packaging/suggests)).
5. Собирает `.deb` через `dpkg-deb`.

glibc (`libc`, `libm`, `ld-linux` и т.д.), `libstdc++` и `libgcc_s` в `libs`
не попадают никогда: сборка падает, если такое случится. Чужая glibc в
`LD_LIBRARY_PATH` ломает всё, что Telegram запускает следом.

Версия пакета — `<версия snap>-<ревизия перепаковки>`. Ревизия лежит в файле
[PKGREV](PKGREV); её надо поднять, чтобы перевыпустить ту же версию Telegram с
изменённой упаковкой.

### Локальная сборка

Нужны arm64-хост, `podman` или `docker`, `curl`, `jq`, `squashfs-tools`, `dpkg-dev`.

```sh
./build.sh                       # текущая stable
./build.sh --version 7.2.9       # конкретная версия, если она ещё есть в каком-то канале стора
./build.sh --snap ./tg.snap      # из готового файла или URL
scripts/smoke-test.sh dist/telegram-desktop-arm64_*.deb
```

Smoke-тест ставит пакет в чистый контейнер 26.04 без `Recommends`, проверяет,
что `ldd` не даёт ни одного `not found`, и запускает Telegram под Xvfb на 20
секунд.

### CI и публикация

[.github/workflows/build.yml](.github/workflows/build.yml) запускается раз в
сутки, по пушу в `main` и вручную. Если пакета с вычисленной версией в
репозитории ещё нет (или запуск ручной), он собирает `.deb`, прогоняет
smoke-тест и только после него публикует:

- релиз `repo` — плоский apt-репозиторий: три последних `.deb`, `Packages`,
  `Packages.gz`, `Release`, `InRelease`, `Release.gpg` и публичный ключ;
- релиз `v<версия>` — тот же `.deb` и список изменений из релиза upstream
  (в API snap-стора changelog нет).

Секреты репозитория:

- `APT_SIGNING_KEY` — приватный GPG-ключ в ASCII-armor;
- `APT_SIGNING_KEY_PASSPHRASE` — парольная фраза, если ключ ею защищён.

GitHub отключает `schedule` в репозиториях без активности 60 дней. Если
обновления перестали приходить, достаточно включить workflow заново на
вкладке Actions.

## Известные шероховатости

- Мини-приложения ботов открываются во встроенном браузере, которому нужен
  `libwebkit2gtk-4.1-0`. Он стоит в `Suggests`, а не в `Recommends`, потому что
  тянет за собой демоны geoclue и avahi. Нужен — `sudo apt install libwebkit2gtk-4.1-0`.

- В логе при старте бывает `Failed to initialize EGL display` — безвредно.
- Пакет рассчитан на Ubuntu 26.04: `Depends` вычислен под её имена пакетов.
