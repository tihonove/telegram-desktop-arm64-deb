#!/usr/bin/env bash
# Publishes a built .deb:
#   1) a v<version> release with the package itself and the changelog;
#   2) a release with the permanent "repo" tag: a flat apt repository.
# Requires: gh (GH_TOKEN, GH_REPO or running inside a clone), an imported GPG key.
set -euo pipefail

deb=$(realpath "${1:?usage: publish.sh path/to/package.deb}")
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
REPO_TAG=repo
version=$(dpkg-deb -f "$deb" Version)
upstream=${version%-*}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

gpg --batch --list-secret-keys --with-colons | grep -q '^sec' \
    || { echo "ERROR: no signing key (is the APT_SIGNING_KEY secret set?)" >&2; exit 1; }

# --- apt repository: old .debs + the new one, index, signature ---------------
mkdir "$tmp/repo"
if gh release view "$REPO_TAG" >/dev/null 2>&1; then
    gh release download "$REPO_TAG" --pattern '*.deb' --dir "$tmp/repo" || true
    mapfile -t old_assets < <(gh release view "$REPO_TAG" --json assets --jq '.assets[].name')
else
    old_assets=()
    gh release create "$REPO_TAG" --latest=false --title "apt repository" \
        --notes "Flat apt repository. Do not delete: apt points at this release's assets. See the README for setup."
fi
cp -f "$deb" "$tmp/repo/"
"$ROOT/scripts/make-repo.sh" "$tmp/repo"

# packages first, then the index: keeps the window where the index points to a missing file minimal
gh release upload "$REPO_TAG" --clobber "$tmp"/repo/*.deb
gh release upload "$REPO_TAG" --clobber "$tmp"/repo/{Packages,Packages.gz,Release,Release.gpg,InRelease} "$tmp"/repo/*.asc
for asset in "${old_assets[@]}"; do
    if [ ! -e "$tmp/repo/$asset" ]; then
        echo "Removing from repository: $asset" >&2
        gh release delete-asset "$REPO_TAG" "$asset" --yes
    fi
done

# --- version release ----------------------------------------------------------
{
    echo "Unofficial repack of the official Telegram Desktop **$upstream** arm64 snap into a \`.deb\`."
    echo
    echo "\`\`\`"
    dpkg-deb -f "$deb" Package Version Architecture Installed-Size
    echo "SHA256: $(sha256sum "$deb" | cut -d' ' -f1)"
    echo "\`\`\`"
    echo
    echo "<details><summary>Bundled libraries</summary>"
    echo
    echo "\`\`\`"
    dpkg-deb --fsys-tarfile "$deb" | tar -xO --wildcards '*/bundled-libs.txt'
    echo "\`\`\`"
    echo "</details>"
    # The Snap Store API has no changelog, so use the upstream release notes
    notes=$(gh api "repos/telegramdesktop/tdesktop/releases/tags/v$upstream" --jq .body 2>/dev/null || true)
    if [ -n "$notes" ]; then
        echo
        echo "## What's new in Telegram Desktop $upstream"
        echo
        echo "$notes"
    fi
} >"$tmp/notes.md"

if gh release view "v$version" >/dev/null 2>&1; then
    gh release upload "v$version" --clobber "$deb"
    gh release edit "v$version" --notes-file "$tmp/notes.md"
else
    gh release create "v$version" "$deb" --latest --title "Telegram Desktop $version" --notes-file "$tmp/notes.md"
fi
