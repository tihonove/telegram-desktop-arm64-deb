#!/usr/bin/env bash
# Перепаковывает официальный arm64-snap Telegram Desktop в .deb.
# Одинаково работает локально (podman) и в CI (docker).
set -euo pipefail

usage() {
    cat <<'EOF'
Использование: ./build.sh [опции]

  (без опций)          собрать текущую stable-версию из snap-стора
  --version X.Y.Z      собрать указанную версию (должна быть в одном из каналов стора)
  --channel NAME       канал стора (по умолчанию stable)
  --snap URL|ФАЙЛ      взять готовый .snap вместо запроса к стору
  --print-version      только напечатать версию будущего пакета и выйти

Переменные окружения:
  CONTAINER_ENGINE     podman или docker (по умолчанию — что найдётся)
  PKGREV               ревизия перепаковки (по умолчанию из файла PKGREV)
  DEB_MAINTAINER       поле Maintainer
  TARGET_IMAGE         образ целевой системы (ubuntu:26.04)
  DONOR_IMAGE          образ, из репозиториев которого добираются библиотеки (ubuntu:24.04)

Результат: dist/telegram-desktop-arm64_<версия>-<ревизия>_arm64.deb
EOF
}

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PKG=telegram-desktop-arm64
TRIPLET=aarch64-linux-gnu
SNAP_NAME=telegram-desktop
PKGREV=${PKGREV:-$(tr -d '[:space:]' <"$ROOT/PKGREV")}
DEB_MAINTAINER=${DEB_MAINTAINER:-"telegram-desktop-arm64-deb (unofficial repack) <noreply@github.com>"}
TARGET_IMAGE=${TARGET_IMAGE:-docker.io/library/ubuntu:26.04}
DONOR_IMAGE=${DONOR_IMAGE:-docker.io/library/ubuntu:24.04}
# Эти библиотеки в пакет не попадают никогда: чужая glibc в LD_LIBRARY_PATH
# ломает всё, что запускается следом.
FORBIDDEN='^(ld-linux.*|libc|libm|libdl|libpthread|librt|libresolv|libutil|libnsl|libanl|libBrokenLocale|libstdc\+\+|libgcc_s)\.so'

WORK=$ROOT/work
DIST=$ROOT/dist

channel=stable
want_version=
snap_src=
print_version=0
while [ $# -gt 0 ]; do
    case $1 in
        --version) want_version=$2; shift 2 ;;
        --channel) channel=$2; shift 2 ;;
        --snap) snap_src=$2; shift 2 ;;
        --print-version) print_version=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done

log() { printf '\033[1m==> %s\033[0m\n' "$*" >&2; }
die() { echo "ОШИБКА: $*" >&2; exit 1; }

# Печатает "version revision url sha3-384" для arm64-сборки из стора
store_lookup() {
    curl -fsS -H 'Snap-Device-Series: 16' -H 'Snap-Device-Architecture: arm64' \
        "https://api.snapcraft.io/v2/snaps/info/$SNAP_NAME?fields=download,version,revision" \
    | jq -r --arg ch "$channel" --arg v "$want_version" '
        [."channel-map"[] | select(.channel.architecture == "arm64")]
        | if $v != "" then map(select(.version == $v)) else map(select(.channel.name == $ch)) end
        | first // empty
        | "\(.version) \(.revision) \(.download.url) \(.download."sha3-384")"'
}

snap_version= snap_revision= snap_url= snap_sha=
if [ -z "$snap_src" ]; then
    read -r snap_version snap_revision snap_url snap_sha < <(store_lookup) || true
    [ -n "$snap_version" ] || die "в сторе нет arm64-сборки (канал '$channel', версия '${want_version:-любая}')"
fi

if [ "$print_version" = 1 ]; then
    [ -n "$snap_version" ] || die "--print-version не работает вместе с --snap"
    echo "$snap_version-$PKGREV"
    exit 0
fi

[ "$(uname -m)" = aarch64 ] || die "сборка рассчитана на arm64-хост (ldd гоняется в arm64-контейнере)"
for tool in curl jq unsquashfs dpkg-deb openssl; do
    command -v "$tool" >/dev/null || die "не найден $tool"
done
ENGINE=${CONTAINER_ENGINE:-$(command -v podman || command -v docker || true)}
[ -n "$ENGINE" ] || die "нужен podman или docker"

mkdir -p "$WORK/cache" "$DIST"

# --- 1. snap ---------------------------------------------------------------
if [ -n "$snap_src" ]; then
    if [ -f "$snap_src" ]; then
        snap_file=$(realpath "$snap_src")
    else
        snap_file=$WORK/cache/custom.snap
        log "Скачиваю $snap_src"
        curl -fL --retry 3 -o "$snap_file" "$snap_src"
    fi
else
    snap_file=$WORK/cache/${SNAP_NAME}_${snap_revision}.snap
    if [ ! -f "$snap_file" ]; then
        log "Скачиваю snap $snap_version (ревизия $snap_revision)"
        curl -fL --retry 3 -o "$snap_file.part" "$snap_url"
        mv "$snap_file.part" "$snap_file"
    fi
    actual=$(openssl dgst -sha3-384 -r "$snap_file" | cut -d' ' -f1)
    [ "$actual" = "$snap_sha" ] || { rm -f "$snap_file"; die "sha3-384 скачанного snap не совпадает с заявленным"; }
fi

STAGE=$WORK/stage
rm -rf "$STAGE" "$WORK/pkgroot"
mkdir -p "$STAGE/libs"
log "Распаковываю snap"
unsquashfs -q -n -d "$STAGE/app" "$snap_file"
[ -x "$STAGE/app/usr/bin/telegram-desktop" ] || die "в snap нет usr/bin/telegram-desktop"

# версия и архитектура — из самого snap, чтобы --snap работал без стора
snap_version=$(sed -n 's/^version: *//p' "$STAGE/app/meta/snap.yaml" | tr -d "'\"")
grep -qx -- '- arm64' "$STAGE/app/meta/snap.yaml" || die "snap собран не под arm64"
snap_revision=${snap_revision:-unknown}
VERSION=$snap_version-$PKGREV
: >"$STAGE/bundled-libs.txt"

# --- 2. недостающие библиотеки ----------------------------------------------
target=tgbuild-target-$$
donor=tgbuild-donor-$$
cleanup() { "$ENGINE" rm -f "$target" "$donor" >/dev/null 2>&1 || true; }
trap cleanup EXIT

log "Поднимаю контейнеры: $TARGET_IMAGE (целевая система), $DONOR_IMAGE (донор библиотек)"
for pair in "$target=$TARGET_IMAGE" "$donor=$DONOR_IMAGE"; do
    "$ENGINE" run -d --rm --name "${pair%%=*}" \
        -v "$STAGE:/work" -v "$ROOT/scripts:/scripts:ro" \
        "${pair#*=}" sleep infinity >/dev/null
done
in_target() { "$ENGINE" exec "$target" /scripts/container-helper.sh "$@"; }
in_donor() { "$ENGINE" exec "$donor" /scripts/container-helper.sh "$@"; }

in_target setup &
in_donor setup &
wait -n && wait -n || die "не удалось подготовить контейнеры"

log "Вычисляю недостающие библиотеки"
for round in $(seq 1 20); do
    mapfile -t missing < <(in_target missing)
    [ ${#missing[@]} -gt 0 ] || break
    for so in "${missing[@]}"; do
        [[ ! $so =~ $FORBIDDEN ]] || die "$so не найдена в целевой системе — бандлить её нельзя"
    done

    # сначала — из репозиториев целевой системы (уйдёт в Depends)
    mapfile -t missing < <(in_target provide "${missing[@]}")
    [ ${#missing[@]} -gt 0 ] || continue

    # потом — из самого snap
    foreign=()
    for so in "${missing[@]}"; do
        if [ -e "$STAGE/app/usr/lib/$TRIPLET/$so" ]; then
            ln -s "../app/usr/lib/$TRIPLET/$so" "$STAGE/libs/$so"
            echo "$so  snap: usr/lib/$TRIPLET/$so" >>"$STAGE/bundled-libs.txt"
            echo "snap: $so" >&2
        else
            foreign+=("$so")
        fi
    done

    # остальное — из .deb донорского релиза
    [ ${#foreign[@]} -eq 0 ] || in_donor fetch "${foreign[@]}"
done
left=$(in_target missing)
[ -z "$left" ] || die "зависимости не сошлись: $(echo $left)"

mapfile -t depends < <(in_target depends)
[ ${#depends[@]} -gt 0 ] || die "не удалось вычислить Depends"
# из списков берём только пакеты, существующие в целевом релизе
existing() { grep -v '^#' "$1" | xargs "$ENGINE" exec "$target" /scripts/container-helper.sh existing; }
mapfile -t recommends < <(existing "$ROOT/packaging/recommends")
mapfile -t suggests < <(existing "$ROOT/packaging/suggests")
in_target chown
cleanup

if find "$STAGE/libs" -mindepth 1 -printf '%f\n' | grep -E "$FORBIDDEN"; then
    die "в libs попала системная библиотека из запрещённого списка"
fi
sort -o "$STAGE/bundled-libs.txt" "$STAGE/bundled-libs.txt"
log "Забандлено: $(wc -l <"$STAGE/bundled-libs.txt") библиотек; Depends: ${#depends[@]} пакетов"

# --- 3. дерево пакета --------------------------------------------------------
log "Собираю дерево пакета"
P=$WORK/pkgroot
mkdir -p "$P/opt/telegram-desktop" "$P/usr/bin" "$P/usr/share/applications" "$P/usr/share/doc/$PKG" "$P/DEBIAN"
rmdir "$STAGE/app/gpu-2404" 2>/dev/null || true # пустая точка монтирования content-снапа
mv "$STAGE/app" "$STAGE/libs" "$P/opt/telegram-desktop/"
install -m 755 "$ROOT/packaging/telegram-desktop" "$P/usr/bin/telegram-desktop"
install -m 644 "$ROOT/packaging/org.telegram.desktop.desktop" "$P/usr/share/applications/"
install -m 644 "$ROOT/packaging/copyright" "$STAGE/bundled-libs.txt" "$P/usr/share/doc/$PKG/"

# Иконки: в snap они названы snap.telegram-desktop.*, а Telegram и .desktop
# ищут org.telegram.desktop*
icons_src=$P/opt/telegram-desktop/app/usr/share/icons/hicolor
while IFS= read -r -d '' icon; do
    rel=${icon#"$icons_src/"}
    name=$(basename "$rel")
    install -D -m 644 "$icon" "$P/usr/share/icons/hicolor/$(dirname "$rel")/org.telegram.desktop${name#snap.telegram-desktop.}"
done < <(find "$icons_src" -type f -name 'snap.telegram-desktop.*' -print0)
for icon in symbolic/apps/org.telegram.desktop{,-mute,-attention}-symbolic.svg 256x256/apps/org.telegram.desktop.png; do
    [ -f "$P/usr/share/icons/hicolor/$icon" ] || die "в snap нет ожидаемой иконки ($icon) — проверь раскладку"
done

find "$P" -type d -exec chmod 755 {} +
chmod -R u+rwX,go+rX,go-w "$P"

join_list() { local IFS=,; echo "$*" | sed 's/,/, /g'; }
sed -e "s|@VERSION@|$VERSION|g" \
    -e "s|@MAINTAINER@|$DEB_MAINTAINER|" \
    -e "s|@INSTALLED_SIZE@|$(du -sk --exclude=DEBIAN "$P" | cut -f1)|" \
    -e "s|@DEPENDS@|$(join_list "${depends[@]}")|" \
    -e "s|@RECOMMENDS@|$(join_list "${recommends[@]}")|" \
    -e "s|@SUGGESTS@|$(join_list "${suggests[@]}")|" \
    -e "s|@SNAP_REVISION@|$snap_revision|" \
    "$ROOT/packaging/control.in" >"$P/DEBIAN/control"
(cd "$P" && find . -type f ! -path './DEBIAN/*' -printf '%P\0' | sort -z | xargs -0 md5sum >DEBIAN/md5sums)

# --- 4. .deb -----------------------------------------------------------------
deb=$DIST/${PKG}_${VERSION}_arm64.deb
log "Упаковываю $(basename "$deb")"
dpkg-deb --root-owner-group -Zxz --build "$P" "$deb" >&2
rm -rf "$P" "$STAGE"
echo "$deb"
