# Usage

## What the package installs

| Path | Contents |
| --- | --- |
| `/opt/telegram-desktop/app` | the snap contents as is |
| `/opt/telegram-desktop/libs` | libraries missing from Ubuntu 26.04 (ICU 74, ffmpeg 6 and their dependencies) |
| `/usr/bin/telegram-desktop` | launcher script: adds only `libs` to `LD_LIBRARY_PATH` |
| `/usr/share/applications/org.telegram.desktop.desktop` | desktop entry and `tg://`, `tonsite://` handlers |
| `/usr/share/icons/hicolor/…/org.telegram.desktop*` | icons, including monochrome tray icons |
| `/usr/share/doc/telegram-desktop-arm64/bundled-libs.txt` | where each bundled library came from |

Data and the session live in `~/.local/share/TelegramDesktop`; the package does not touch them.

## Rollback

The repository keeps the three latest versions; older ones are in the `v<version>` releases.

```sh
apt list -a telegram-desktop-arm64                 # list available versions
sudo apt install telegram-desktop-arm64=7.2.9-1    # install a specific one
sudo apt-mark hold telegram-desktop-arm64          # don't upgrade until the hold is removed
sudo apt-mark unhold telegram-desktop-arm64
```

Versions no longer in the repository are installed from a release:
download the `.deb` from the `v<version>` page and run `sudo apt install ./telegram-desktop-arm64_<version>_arm64.deb`.

To remove completely:

```sh
sudo apt purge telegram-desktop-arm64
sudo rm /etc/apt/sources.list.d/telegram-desktop-arm64.list /etc/apt/keyrings/telegram-desktop-arm64.asc
```

## Migrating from a manual install

If Telegram was already unpacked from the snap by hand into `~/.local/opt/telegram`:

1. Quit Telegram (use "Quit" in the tray menu, not just closing the window).
2. Move the old install out of the way without deleting it yet. `~/.local/bin` comes
   before `/usr/bin` in `PATH`, so otherwise the old launcher would shadow the new one:

   ```sh
   mv ~/.local/opt/telegram ~/.local/opt/telegram.manual-backup
   mv ~/.local/bin/telegram-desktop ~/.local/bin/telegram-desktop.manual-backup
   mv ~/.local/share/applications/org.telegram.desktop.desktop{,.manual-backup}
   ```

3. Add the repository and install the package (see the [README](../README.md#setup)).
4. Run `telegram-desktop`. The session is picked up from `~/.local/share/TelegramDesktop`.
5. Once everything works, remove the leftovers:

   ```sh
   rm -rf ~/.local/opt/telegram.manual-backup
   rm -f ~/.local/bin/telegram-desktop.manual-backup
   rm -f ~/.local/share/applications/org.telegram.desktop.desktop.manual-backup
   rm -f ~/.local/share/icons/hicolor/symbolic/apps/org.telegram.desktop*-symbolic.svg
   ```

## Known rough edges

- Bot mini apps open in the built-in browser, which needs
  `libwebkit2gtk-4.1-0`. It is in `Suggests` rather than `Recommends` because it
  pulls in the geoclue and avahi daemons. If you need it: `sudo apt install libwebkit2gtk-4.1-0`.

- `Failed to initialize EGL display` sometimes shows up in the log at startup — it is harmless.
- The package targets Ubuntu 26.04: `Depends` is computed for its package names.
