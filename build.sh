#!/usr/bin/env bash
# Repacks the official Telegram Desktop arm64 snap into a .deb.
# Works the same locally (podman) and in CI (docker).
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: ./build.sh [options]

  (no options)         build the current stable version from the Snap Store
  --version X.Y.Z      build the given version (must be in one of the store channels)
  --channel NAME       store channel (default: stable)
  --snap URL|FILE      use an existing .snap instead of querying the store
  --print-version      only print the version of the package to be built and exit

Environment variables:
  CONTAINER_ENGINE     podman or docker (default: whichever is found)
  PKGREV               repack revision (default: from the PKGREV file)
  DEB_MAINTAINER       the Maintainer field
  TARGET_IMAGE         target system image (ubuntu:26.04)
  DONOR_IMAGE          image whose repositories supply missing libraries (ubuntu:24.04)

Output: dist/telegram-desktop-arm64_<version>-<revision>_arm64.deb
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
# These libraries never go into the package: a foreign glibc in LD_LIBRARY_PATH
# breaks everything launched afterwards.
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
die() { echo "ERROR: $*" >&2; exit 1; }

# Prints "version revision url sha3-384" for the arm64 build from the store
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
    [ -n "$snap_version" ] || die "no arm64 build in the store (channel '$channel', version '${want_version:-any}')"
fi

if [ "$print_version" = 1 ]; then
    [ -n "$snap_version" ] || die "--print-version does not work with --snap"
    echo "$snap_version-$PKGREV"
    exit 0
fi

[ "$(uname -m)" = aarch64 ] || die "the build requires an arm64 host (ldd runs in an arm64 container)"
for tool in curl jq unsquashfs dpkg-deb openssl; do
    command -v "$tool" >/dev/null || die "$tool not found"
done
ENGINE=${CONTAINER_ENGINE:-$(command -v podman || command -v docker || true)}
[ -n "$ENGINE" ] || die "podman or docker is required"

mkdir -p "$WORK/cache" "$DIST"

# --- 1. snap ---------------------------------------------------------------
if [ -n "$snap_src" ]; then
    if [ -f "$snap_src" ]; then
        snap_file=$(realpath "$snap_src")
    else
        snap_file=$WORK/cache/custom.snap
        log "Downloading $snap_src"
        curl -fL --retry 3 -o "$snap_file" "$snap_src"
    fi
else
    snap_file=$WORK/cache/${SNAP_NAME}_${snap_revision}.snap
    if [ ! -f "$snap_file" ]; then
        log "Downloading snap $snap_version (revision $snap_revision)"
        curl -fL --retry 3 -o "$snap_file.part" "$snap_url"
        mv "$snap_file.part" "$snap_file"
    fi
    actual=$(openssl dgst -sha3-384 -r "$snap_file" | cut -d' ' -f1)
    [ "$actual" = "$snap_sha" ] || { rm -f "$snap_file"; die "sha3-384 of the downloaded snap does not match the expected one"; }
fi

STAGE=$WORK/stage
rm -rf "$STAGE" "$WORK/pkgroot"
mkdir -p "$STAGE/libs"
log "Unpacking snap"
unsquashfs -q -n -d "$STAGE/app" "$snap_file"
[ -x "$STAGE/app/usr/bin/telegram-desktop" ] || die "snap has no usr/bin/telegram-desktop"

# version and architecture come from the snap itself so that --snap works without the store
snap_version=$(sed -n 's/^version: *//p' "$STAGE/app/meta/snap.yaml" | tr -d "'\"")
grep -qx -- '- arm64' "$STAGE/app/meta/snap.yaml" || die "snap is not built for arm64"
snap_revision=${snap_revision:-unknown}
VERSION=$snap_version-$PKGREV
: >"$STAGE/bundled-libs.txt"

# --- 2. missing libraries --------------------------------------------------
target=tgbuild-target-$$
donor=tgbuild-donor-$$
cleanup() { "$ENGINE" rm -f "$target" "$donor" >/dev/null 2>&1 || true; }
trap cleanup EXIT

log "Starting containers: $TARGET_IMAGE (target system), $DONOR_IMAGE (library donor)"
for pair in "$target=$TARGET_IMAGE" "$donor=$DONOR_IMAGE"; do
    "$ENGINE" run -d --rm --name "${pair%%=*}" \
        -v "$STAGE:/work" -v "$ROOT/scripts:/scripts:ro" \
        "${pair#*=}" sleep infinity >/dev/null
done
in_target() { "$ENGINE" exec "$target" /scripts/container-helper.sh "$@"; }
in_donor() { "$ENGINE" exec "$donor" /scripts/container-helper.sh "$@"; }

in_target setup &
in_donor setup &
wait -n && wait -n || die "failed to prepare containers"

log "Resolving missing libraries"
for round in $(seq 1 20); do
    mapfile -t missing < <(in_target missing)
    [ ${#missing[@]} -gt 0 ] || break
    for so in "${missing[@]}"; do
        [[ ! $so =~ $FORBIDDEN ]] || die "$so not found in the target system and must not be bundled"
    done

    # first, from the target system repositories (goes to Depends)
    mapfile -t missing < <(in_target provide "${missing[@]}")
    [ ${#missing[@]} -gt 0 ] || continue

    # then, from the snap itself
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

    # the rest, from .debs of the donor release
    [ ${#foreign[@]} -eq 0 ] || in_donor fetch "${foreign[@]}"
done
left=$(in_target missing)
[ -z "$left" ] || die "unresolved dependencies: $(echo $left)"

mapfile -t depends < <(in_target depends)
[ ${#depends[@]} -gt 0 ] || die "failed to compute Depends"
# take only the listed packages that exist in the target release
existing() { grep -v '^#' "$1" | xargs "$ENGINE" exec "$target" /scripts/container-helper.sh existing; }
mapfile -t recommends < <(existing "$ROOT/packaging/recommends")
mapfile -t suggests < <(existing "$ROOT/packaging/suggests")
in_target chown
cleanup

if find "$STAGE/libs" -mindepth 1 -printf '%f\n' | grep -E "$FORBIDDEN"; then
    die "a forbidden system library ended up in libs"
fi
sort -o "$STAGE/bundled-libs.txt" "$STAGE/bundled-libs.txt"
log "Bundled: $(wc -l <"$STAGE/bundled-libs.txt") libraries; Depends: ${#depends[@]} packages"

# --- 3. package tree --------------------------------------------------------
log "Assembling package tree"
P=$WORK/pkgroot
mkdir -p "$P/opt/telegram-desktop" "$P/usr/bin" "$P/usr/share/applications" "$P/usr/share/doc/$PKG" "$P/DEBIAN"
rmdir "$STAGE/app/gpu-2404" 2>/dev/null || true # empty mount point of the content snap
mv "$STAGE/app" "$STAGE/libs" "$P/opt/telegram-desktop/"
install -m 755 "$ROOT/packaging/telegram-desktop" "$P/usr/bin/telegram-desktop"
install -m 644 "$ROOT/packaging/org.telegram.desktop.desktop" "$P/usr/share/applications/"
install -m 644 "$ROOT/packaging/copyright" "$STAGE/bundled-libs.txt" "$P/usr/share/doc/$PKG/"

# Icons: in the snap they are named snap.telegram-desktop.*, while Telegram and
# the .desktop file look for org.telegram.desktop*
icons_src=$P/opt/telegram-desktop/app/usr/share/icons/hicolor
while IFS= read -r -d '' icon; do
    rel=${icon#"$icons_src/"}
    name=$(basename "$rel")
    install -D -m 644 "$icon" "$P/usr/share/icons/hicolor/$(dirname "$rel")/org.telegram.desktop${name#snap.telegram-desktop.}"
done < <(find "$icons_src" -type f -name 'snap.telegram-desktop.*' -print0)
for icon in symbolic/apps/org.telegram.desktop{,-mute,-attention}-symbolic.svg 256x256/apps/org.telegram.desktop.png; do
    [ -f "$P/usr/share/icons/hicolor/$icon" ] || die "expected icon ($icon) missing from snap; check the layout"
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
log "Packing $(basename "$deb")"
dpkg-deb --root-owner-group -Zxz --build "$P" "$deb" >&2
rm -rf "$P" "$STAGE"
echo "$deb"
