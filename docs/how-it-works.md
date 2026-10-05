# How it works

`build.sh` does the same thing locally and in CI:

1. Asks the Snap Store API for the stable arm64 revision, downloads the snap,
   verifies its sha3-384 and unpacks it with `unsquashfs`.
2. Starts two containers: `ubuntu:26.04` (the target system) and `ubuntu:24.04`
   (the base the snap is built on, `core24`).
3. Runs `ldd` in the 26.04 container and, for each missing library, tries in
   order:
   - a package from the 26.04 repositories — the library then goes to `Depends`;
   - a file from the snap itself;
   - a `.deb` from 24.04 on ports.ubuntu.com — the library is then put into `libs`.

   The loop repeats until there are no more `not found` entries, so transitive
   dependencies get pulled in too. The list is not hardcoded anywhere and will
   survive a change of the snap base (just change `DONOR_IMAGE`).
4. `Depends` lists the 26.04 packages that resolve the direct dependencies of the
   binary and the bundled libraries. `Recommends` and `Suggests` are what Telegram
   loads via `dlopen` ([packaging/recommends](../packaging/recommends),
   [packaging/suggests](../packaging/suggests)).
5. Builds the `.deb` with `dpkg-deb`.

glibc (`libc`, `libm`, `ld-linux`, etc.), `libstdc++` and `libgcc_s` never end up
in `libs`: the build fails if that happens. A foreign glibc in `LD_LIBRARY_PATH`
breaks everything Telegram launches afterwards.

The package version is `<snap version>-<repack revision>`. The revision lives in
the [PKGREV](../PKGREV) file; bump it to re-release the same Telegram version with
changed packaging.

## Local build

Requires an arm64 host, `podman` or `docker`, `curl`, `jq`, `squashfs-tools`, `dpkg-dev`.

```sh
./build.sh                       # current stable
./build.sh --version 7.2.9       # a specific version, if it is still in some store channel
./build.sh --snap ./tg.snap      # from an existing file or URL
scripts/smoke-test.sh dist/telegram-desktop-arm64_*.deb
```

The smoke test installs the package into a clean 26.04 container without
`Recommends`, checks that `ldd` reports no `not found`, and runs Telegram under
Xvfb for 20 seconds.

## CI and publishing

[.github/workflows/build.yml](../.github/workflows/build.yml) runs once a day, on
push to `main` and manually. If the repository doesn't have a package with the
computed version yet (or the run is manual), it builds the `.deb`, runs the smoke
test and only then publishes:

- the `repo` release — a flat apt repository: the three latest `.deb` files,
  `Packages`, `Packages.gz`, `Release`, `InRelease`, `Release.gpg` and the public key;
- the `v<version>` release — the same `.deb` and the changelog from the upstream
  release (the Snap Store API has no changelog).

Repository secrets:

- `APT_SIGNING_KEY` — the private GPG key in ASCII armor;
- `APT_SIGNING_KEY_PASSPHRASE` — its passphrase, if the key is protected by one.

GitHub disables `schedule` in repositories with no activity for 60 days. If
updates stop arriving, just re-enable the workflow on the Actions tab.
