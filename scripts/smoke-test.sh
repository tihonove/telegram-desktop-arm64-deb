#!/usr/bin/env bash
# Smoke-тест: ставит .deb в чистый контейнер целевой системы и проверяет,
# что зависимости сходятся и Telegram запускается.
set -euo pipefail

deb=$(realpath "${1:?использование: smoke-test.sh путь/к/пакету.deb}")
ENGINE=${CONTAINER_ENGINE:-$(command -v podman || command -v docker)}
TARGET_IMAGE=${TARGET_IMAGE:-docker.io/library/ubuntu:26.04}

"$ENGINE" run --rm -i -v "$(dirname "$deb"):/pkg:ro" -e DEB="/pkg/$(basename "$deb")" "$TARGET_IMAGE" bash -s <<'EOF'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
TG=/opt/telegram-desktop
BIN=$TG/app/usr/bin/telegram-desktop
fail() { echo "FAIL: $*" >&2; exit 1; }

echo "--- apt install (без Recommends: Depends должно хватать)"
apt-get update -qq
apt-get install -y -qq --no-install-recommends "$DEB" >/dev/null

echo "--- раскладка"
for f in /usr/bin/telegram-desktop "$BIN" \
    /usr/share/applications/org.telegram.desktop.desktop \
    /usr/share/icons/hicolor/256x256/apps/org.telegram.desktop.png \
    /usr/share/icons/hicolor/symbolic/apps/org.telegram.desktop-symbolic.svg \
    /usr/share/icons/hicolor/symbolic/apps/org.telegram.desktop-mute-symbolic.svg \
    /usr/share/icons/hicolor/symbolic/apps/org.telegram.desktop-attention-symbolic.svg; do
    [ -e "$f" ] || fail "нет $f"
done
if ls "$TG/libs" | grep -E '^(ld-linux.*|libc|libm|libdl|libpthread|librt|libstdc\+\+|libgcc_s)\.so'; then
    fail "в libs лежит системная библиотека"
fi

echo "--- ldd"
for f in "$BIN" "$TG"/libs/*; do
    out=$(LD_LIBRARY_PATH=$TG/libs ldd "$f")
    if grep 'not found' <<<"$out"; then fail "неразрешённые зависимости у $f"; fi
done
LD_LIBRARY_PATH=$TG/libs ldd "$BIN" | grep -E '/libc\.so\.6|/libm\.so\.6' | grep -q "$TG" && fail "glibc резолвится из libs"

# Qt в бинаре собран только с wayland и xcb (offscreen нет), поэтому Xvfb
echo "--- запуск (Xvfb, 20 секунд)"
apt-get install -y -qq --no-install-recommends xvfb xauth >/dev/null
export HOME=/tmp/home XDG_RUNTIME_DIR=/tmp/run QT_QPA_PLATFORM=xcb
mkdir -p "$HOME" "$XDG_RUNTIME_DIR" && chmod 700 "$XDG_RUNTIME_DIR"
rc=0
xvfb-run -a timeout -s TERM -k 5 20 telegram-desktop -workdir "$HOME/tg/" >/tmp/tg.log 2>&1 || rc=$?
tail -n 20 /tmp/tg.log
# 124 — дожил до таймаута; 0 — корректно вышел по SIGTERM
case $rc in
    124|0) ;;
    *) fail "telegram-desktop завершился с кодом $rc" ;;
esac
[ -d "$HOME/tg/tdata" ] || fail "Telegram не создал рабочий каталог — похоже, не стартовал"
echo "OK: smoke-тест пройден"
EOF
