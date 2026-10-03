#!/usr/bin/env bash
# Выполняется ВНУТРИ контейнеров сборки (resolute и noble), на хосте не запускать.
# /work/app  — распакованный snap
# /work/libs — библиотеки, которые поедут в пакет
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

TRIPLET=aarch64-linux-gnu
BIN=/work/app/usr/bin/telegram-desktop
MANIFEST=/work/bundled-libs.txt

targets() {
    echo "$BIN"
    find /work/libs -maxdepth 1 \( -type f -o -type l \) -name '*.so*' | sort
}

run_ldd() {
    local t
    targets | while read -r t; do
        LD_LIBRARY_PATH=/work/libs ldd "$t" 2>/dev/null || true
    done
}

INDEX=/var/tmp/solibs.idx

quiet() {
    local log
    log=$(mktemp)
    "$@" >"$log" 2>&1 || { cat "$log" >&2; exit 1; }
    rm -f "$log"
}

cmd_setup() {
    quiet apt-get update
    quiet apt-get install -y --no-install-recommends apt-file binutils
    quiet apt-file update
    # Один проход по Contents вместо поиска на каждый soname: "пакет: путь"
    apt-file search -x "^/usr/lib/$TRIPLET/.*\.so(\.|\$)" >"$INDEX"
}

# Пакет, в котором лежит soname. $2 = direct — только прямо в libdir (то, что
# найдёт ld.so без LD_LIBRARY_PATH), any — в том числе в подкаталогах.
# Если пакетов несколько (libavcodec60 / libavcodec-extra60, libegl1 /
# libegl-mali-*), берём самый короткий путь, затем самое короткое имя пакета:
# так выигрывает основной вариант, а не -extra и не вендорская замена.
provider() {
    awk -F': ' -v so="$1" -v mode="$2" -v dir="/usr/lib/$TRIPLET/" '
        {
            n = split($2, a, "/")
            if (a[n] != so) next
            if (mode == "direct" && $2 != dir so) next
            print length($2), length($1), $1
        }' "$INDEX" | sort -k1,1n -k2,2n -k3,3 | head -n1 | cut -d' ' -f3
}

# soname'ы, которые не резолвятся ни из системы, ни из /work/libs
cmd_missing() {
    run_ldd | awk '/not found/ {print $1}' | sort -u
}

# resolute: поставить пакеты, в которых есть запрошенные soname'ы.
# На stdout — soname'ы, которых в дистрибутиве нет.
cmd_provide() {
    local so pkg pkgs=()
    for so in "$@"; do
        pkg=$(provider "$so" direct)
        if [ -n "$pkg" ]; then
            pkgs+=("$pkg")
        else
            echo "$so"
        fi
    done
    if [ ${#pkgs[@]} -gt 0 ]; then
        echo "resolute: ставлю ${pkgs[*]}" >&2
        quiet apt-get install -y --no-install-recommends -o Dpkg::Options::=--force-unsafe-io "${pkgs[@]}"
    fi
}

# noble: скачать .deb с запрошенными soname'ами и положить библиотеки в /work/libs
cmd_fetch() {
    local so pkg ver file tmp
    for so in "$@"; do
        pkg=$(provider "$so" any)
        if [ -z "$pkg" ]; then
            echo "ОШИБКА: $so нет ни в целевой системе, ни в snap, ни в доноре" >&2
            exit 1
        fi
        tmp=$(mktemp -d)
        (cd "$tmp" && quiet apt-get download "$pkg" && dpkg-deb -x ./*.deb x)
        file=$(find "$tmp/x" -name "$so" | head -n1)
        ver=$(dpkg-deb -f "$tmp"/*.deb Version)
        cp -L "$file" "/work/libs/$so"
        chmod 644 "/work/libs/$so"
        echo "$so  noble: $pkg $ver" >>"$MANIFEST"
        echo "noble: $so <- $pkg $ver" >&2
        rm -rf "$tmp"
    done
}

# resolute: пакеты с системными библиотеками, от которых бинарь и забандленные
# библиотеки зависят напрямую (DT_NEEDED). Транзитивные подтянет сам apt.
cmd_depends() {
    local so p real
    local -A path=()
    while read -r so p; do path[$so]=$p; done \
        < <(run_ldd | awk '$2 == "=>" && $3 ~ /^\// {print $1, $3} $1 ~ /^\// {n = split($1, a, "/"); print a[n], $1}' | sort -u)
    targets | xargs readelf -d | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p' | sort -u \
    | while read -r so; do
        p=${path[$so]:-}
        [ -n "$p" ] || { echo "ОШИБКА: $so не резолвится" >&2; exit 1; }
        case $p in /work/*) continue ;; esac
        real=$(realpath "$p")
        dpkg -S "$real" 2>/dev/null || dpkg -S "/usr$real" 2>/dev/null || dpkg -S "${real#/usr}" 2>/dev/null \
            || { echo "ОШИБКА: не нашёл пакет для $p" >&2; exit 1; }
    done | cut -d: -f1 | sort -u
}

# какие из перечисленных пакетов существуют в дистрибутиве
cmd_existing() {
    local p
    for p in "$@"; do
        if apt-cache show "$p" >/dev/null 2>&1; then echo "$p"; fi
    done
}

# вернуть хосту владение файлами (в docker контейнер пишет от root)
cmd_chown() {
    chown -R --reference=/work/app /work/libs
    [ -e "$MANIFEST" ] && chown --reference=/work/app "$MANIFEST"
    return 0
}

cmd=$1
shift
"cmd_$cmd" "$@"
