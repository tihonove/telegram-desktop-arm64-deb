#!/usr/bin/env bash
# Публикует собранный .deb:
#   1) релиз v<версия> с самим пакетом и changelog;
#   2) релиз с постоянным тегом "repo" — плоский apt-репозиторий.
# Нужны: gh (GH_TOKEN, GH_REPO или запуск внутри клона), импортированный GPG-ключ.
set -euo pipefail

deb=$(realpath "${1:?использование: publish.sh путь/к/пакету.deb}")
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
REPO_TAG=repo
version=$(dpkg-deb -f "$deb" Version)
upstream=${version%-*}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

gpg --batch --list-secret-keys --with-colons | grep -q '^sec' \
    || { echo "ОШИБКА: нет ключа подписи (секрет APT_SIGNING_KEY не задан?)" >&2; exit 1; }

# --- apt-репозиторий: старые .deb + новый, индекс, подпись --------------------
mkdir "$tmp/repo"
if gh release view "$REPO_TAG" >/dev/null 2>&1; then
    gh release download "$REPO_TAG" --pattern '*.deb' --dir "$tmp/repo" || true
    mapfile -t old_assets < <(gh release view "$REPO_TAG" --json assets --jq '.assets[].name')
else
    old_assets=()
    gh release create "$REPO_TAG" --latest=false --title "apt repository" \
        --notes "Плоский apt-репозиторий. Не удалять: на ассеты этого релиза смотрит apt. Как подключить — см. README."
fi
cp -f "$deb" "$tmp/repo/"
"$ROOT/scripts/make-repo.sh" "$tmp/repo"

# сначала пакеты, потом индекс: окно, когда индекс ссылается на отсутствующий файл, минимально
gh release upload "$REPO_TAG" --clobber "$tmp"/repo/*.deb
gh release upload "$REPO_TAG" --clobber "$tmp"/repo/{Packages,Packages.gz,Release,Release.gpg,InRelease} "$tmp"/repo/*.asc
for asset in "${old_assets[@]}"; do
    if [ ! -e "$tmp/repo/$asset" ]; then
        echo "Удаляю из репозитория: $asset" >&2
        gh release delete-asset "$REPO_TAG" "$asset" --yes
    fi
done

# --- релиз версии --------------------------------------------------------------
{
    echo "Неофициальная перепаковка официального arm64-snap Telegram Desktop **$upstream** в \`.deb\`."
    echo
    echo "\`\`\`"
    dpkg-deb -f "$deb" Package Version Architecture Installed-Size
    echo "SHA256: $(sha256sum "$deb" | cut -d' ' -f1)"
    echo "\`\`\`"
    echo
    echo "<details><summary>Забандленные библиотеки</summary>"
    echo
    echo "\`\`\`"
    dpkg-deb --fsys-tarfile "$deb" | tar -xO --wildcards '*/bundled-libs.txt'
    echo "\`\`\`"
    echo "</details>"
    # В API snap-стора changelog нет, берём заметки к релизу upstream
    notes=$(gh api "repos/telegramdesktop/tdesktop/releases/tags/v$upstream" --jq .body 2>/dev/null || true)
    if [ -n "$notes" ]; then
        echo
        echo "## Что нового в Telegram Desktop $upstream"
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
