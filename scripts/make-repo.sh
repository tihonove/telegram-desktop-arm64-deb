#!/usr/bin/env bash
# Turns a directory of .debs into a flat signed apt repository:
# Packages, Packages.gz, Release, InRelease, Release.gpg and the public key.
# Keeps the KEEP latest versions and deletes the other .debs from the directory.
#
# The signing key comes from the current GPG keyring (GNUPGHOME), the passphrase
# from APT_SIGNING_KEY_PASSPHRASE if set.
set -euo pipefail

dir=${1:?usage: make-repo.sh deb-directory}
KEEP=${KEEP:-3}
KEY_NAME=${KEY_NAME:-telegram-desktop-arm64.asc}
cd "$dir"

# sort by Debian version rules, newest first
mapfile -t debs < <(
    for f in *.deb; do
        printf '%s\t%s\n' "$(dpkg-deb -f "$f" Version)" "$f"
    done | sort -t$'\t' -k1,1Vr | cut -f2
)
[ ${#debs[@]} -gt 0 ] || { echo "no .deb in $dir" >&2; exit 1; }
for f in "${debs[@]:$KEEP}"; do
    echo "Removing old version: $f" >&2
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
[ -s "$KEY_NAME" ] || { echo "no signing key in the keyring" >&2; exit 1; }

ls -l >&2
