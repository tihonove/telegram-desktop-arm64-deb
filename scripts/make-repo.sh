#!/usr/bin/env bash
# Превращает каталог с .deb в плоский подписанный apt-репозиторий:
# Packages, Packages.gz, Release, InRelease, Release.gpg и публичный ключ.
# Оставляет KEEP последних версий, остальные .deb удаляет из каталога.
#
# Ключ подписи берётся из текущего GPG-keyring (GNUPGHOME), парольная фраза —
# из APT_SIGNING_KEY_PASSPHRASE, если задана.
set -euo pipefail

dir=${1:?использование: make-repo.sh каталог-с-deb}
KEEP=${KEEP:-3}
KEY_NAME=${KEY_NAME:-telegram-desktop-arm64.asc}
cd "$dir"

# сортировка по правилам версий Debian, новые первыми
mapfile -t debs < <(
    for f in *.deb; do
        printf '%s\t%s\n' "$(dpkg-deb -f "$f" Version)" "$f"
    done | sort -t$'\t' -k1,1Vr | cut -f2
)
[ ${#debs[@]} -gt 0 ] || { echo "в $dir нет .deb" >&2; exit 1; }
for f in "${debs[@]:$KEEP}"; do
    echo "Удаляю старую версию: $f" >&2
    rm -f "$f"
done

rm -f Packages Packages.gz Release Release.gpg InRelease
dpkg-scanpackages --multiversion . >Packages 2>/dev/null
gzip -9nk Packages

{
    echo "Origin: telegram-desktop-arm64-deb"
    echo "Label: Telegram Desktop arm64 (unofficial snap repack)"
    echo "Suite: stable"
    echo "Architectures: arm64"
    echo "Date: $(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S UTC')"
    for algo in MD5Sum:md5sum SHA256:sha256sum; do
        echo "${algo%%:*}:"
        for f in Packages Packages.gz; do
            printf ' %s %d %s\n' "$("${algo#*:}" "$f" | cut -d' ' -f1)" "$(stat -c %s "$f")" "$f"
        done
    done
} >Release

gpg_sign() {
    if [ -n "${APT_SIGNING_KEY_PASSPHRASE:-}" ]; then
        gpg --batch --yes --pinentry-mode loopback --passphrase-fd 3 "$@" 3<<<"$APT_SIGNING_KEY_PASSPHRASE"
    else
        gpg --batch --yes "$@"
    fi
}
gpg_sign --clearsign -o InRelease Release
gpg_sign --armor --detach-sign -o Release.gpg Release
gpg --batch --yes --armor --export -o "$KEY_NAME"
[ -s "$KEY_NAME" ] || { echo "в keyring нет ключа подписи" >&2; exit 1; }

ls -l >&2
