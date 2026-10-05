#!/usr/bin/env bash
# Runs INSIDE the build containers (resolute and noble); do not run on the host.
# /work/app  — the unpacked snap
# /work/libs — libraries that go into the package
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
    # One pass over Contents instead of a search per soname: "package: path"
    apt-file search -x "^/usr/lib/$TRIPLET/.*\.so(\.|\$)" >"$INDEX"
}

# The package that ships a soname. $2 = direct: only directly in libdir (what
# ld.so finds without LD_LIBRARY_PATH); any: subdirectories too.
# If there are several packages (libavcodec60 / libavcodec-extra60, libegl1 /
# libegl-mali-*), pick the shortest path, then the shortest package name:
# that way the main variant wins, not -extra or a vendor replacement.
provider() {
    awk -F': ' -v so="$1" -v mode="$2" -v dir="/usr/lib/$TRIPLET/" '
        {
            n = split($2, a, "/")
            if (a[n] != so) next
            if (mode == "direct" && $2 != dir so) next
            print length($2), length($1), $1
        }' "$INDEX" | sort -k1,1n -k2,2n -k3,3 | head -n1 | cut -d' ' -f3
}

# sonames that resolve neither from the system nor from /work/libs
cmd_missing() {
    run_ldd | awk '/not found/ {print $1}' | sort -u
}

# resolute: install the packages that ship the requested sonames.
# Prints to stdout the sonames the distribution does not have.
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
        echo "resolute: installing ${pkgs[*]}" >&2
        quiet apt-get install -y --no-install-recommends -o Dpkg::Options::=--force-unsafe-io "${pkgs[@]}"
    fi
}

# noble: download .debs with the requested sonames and put the libraries into /work/libs
cmd_fetch() {
    local so pkg ver file tmp
    for so in "$@"; do
        pkg=$(provider "$so" any)
        if [ -z "$pkg" ]; then
            echo "ERROR: $so is not in the target system, the snap or the donor" >&2
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

# resolute: packages with the system libraries the binary and the bundled
# libraries depend on directly (DT_NEEDED). apt pulls in transitive ones itself.
cmd_depends() {
    local so p real
    local -A path=()
    while read -r so p; do path[$so]=$p; done \
        < <(run_ldd | awk '$2 == "=>" && $3 ~ /^\// {print $1, $3} $1 ~ /^\// {n = split($1, a, "/"); print a[n], $1}' | sort -u)
    targets | xargs readelf -d | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p' | sort -u \
    | while read -r so; do
        p=${path[$so]:-}
        [ -n "$p" ] || { echo "ERROR: $so does not resolve" >&2; exit 1; }
        case $p in /work/*) continue ;; esac
        real=$(realpath "$p")
        dpkg -S "$real" 2>/dev/null || dpkg -S "/usr$real" 2>/dev/null || dpkg -S "${real#/usr}" 2>/dev/null \
            || { echo "ERROR: no package found for $p" >&2; exit 1; }
    done | cut -d: -f1 | sort -u
}

# which of the listed packages exist in the distribution
cmd_existing() {
    local p
    for p in "$@"; do
        if apt-cache show "$p" >/dev/null 2>&1; then echo "$p"; fi
    done
}

# give file ownership back to the host (in docker the container writes as root)
cmd_chown() {
    chown -R --reference=/work/app /work/libs
    [ -e "$MANIFEST" ] && chown --reference=/work/app "$MANIFEST"
    return 0
}

cmd=$1
shift
"cmd_$cmd" "$@"
