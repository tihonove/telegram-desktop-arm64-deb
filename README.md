# telegram-desktop-arm64-deb

An apt repository with Telegram Desktop for **arm64** (aarch64) on Ubuntu 26.04.

This is an **unofficial repack** of the official arm64 build of Telegram Desktop.
Telegram publishes Linux arm64 builds only in the Snap Store: there is no tarball
on the website and no apt package. Here GitHub Actions checks the store's stable
channel once a day, downloads the snap, moves its contents into a `.deb` and
publishes a signed apt repository. The binary is neither rebuilt nor modified.
snapd is not required.

Telegram Desktop is distributed under
[GPLv3 with an OpenSSL exception](https://github.com/telegramdesktop/tdesktop/blob/master/LEGAL);
the source code is at [telegramdesktop/tdesktop](https://github.com/telegramdesktop/tdesktop).
This project is not affiliated with or supported by Telegram.

## Setup

```sh
sudo install -d -m 755 /etc/apt/keyrings
sudo curl -fsSL -o /etc/apt/keyrings/telegram-desktop-arm64.asc \
  https://github.com/tihonove/telegram-desktop-arm64-deb/releases/download/repo/telegram-desktop-arm64.asc
echo "deb [signed-by=/etc/apt/keyrings/telegram-desktop-arm64.asc] https://github.com/tihonove/telegram-desktop-arm64-deb/releases/download/repo ./" \
  | sudo tee /etc/apt/sources.list.d/telegram-desktop-arm64.list
sudo apt update
sudo apt install telegram-desktop-arm64
```

After that, updates arrive with a regular `apt upgrade`.

## More

- [Usage](docs/usage.md) — what gets installed, rollback, removal, migrating from a manual install, known issues
- [How it works](docs/how-it-works.md) — the build, local builds, CI and publishing
