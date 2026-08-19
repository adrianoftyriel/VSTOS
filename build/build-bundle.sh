#!/usr/bin/env bash
# Build the VSTOS provisioning bundle - the thing a release actually ships.
#
#   ./build/build-bundle.sh                 dist/vstos-<version>.tar.gz
#   ./build/build-bundle.sh --tag v0.1.0-dev.3 --out dist
#
# The bundle is the provisioner, the files it installs, and the documentation:
# everything needed to turn a minimal Ubuntu 24.04 Server install into VSTOS,
# with no network access to this repository required.
#
# It is what a release carries instead of an ISO. A GitHub release asset is
# capped at 2 GB and an Ubuntu-based installer image is comfortably past that, so
# an ISO cannot be attached to one at all. The bundle is a few hundred kilobytes,
# it is the same code the ISO runs, and `build/build-iso.sh` in it rebuilds the
# image in a single command - which is a better deal than a 3 GB download anyway.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
TAG=""
OUT="$ROOT/dist"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --tag) TAG="${2:?}"; shift ;;
        --out) OUT="${2:?}"; shift ;;
        --help|-h) sed -n '2,14p' "$0" | sed 's/^# \?//'; exit 0 ;;
        *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
    shift
done

[ -n "$VERSION" ] || { printf 'error: VERSION is empty\n' >&2; exit 1; }
name="vstos-${TAG:-v$VERSION}"
name="${name/#vstos-v/vstos-}"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
stage="$work/$name"
mkdir -p "$stage"

# Only what a target machine needs. Tests and CI configuration are for developing
# VSTOS, not for running it, and shipping them invites someone to run the test
# suite on an appliance and wonder why it wants shellcheck.
cp -a "$ROOT/provision" "$ROOT/system" "$ROOT/build" "$ROOT/docs" "$stage/"
cp -a "$ROOT/README.md" "$ROOT/LICENSE" "$ROOT/VERSION" "$stage/"
rm -rf "$stage/build"/*.iso "$stage/build"/*.iso.* 2>/dev/null || true

# Stamp the exact version into the bundle, so a machine can say what it was built
# from even after the tarball is long gone.
printf '%s\n' "${TAG:-v$VERSION}" > "$stage/RELEASE"

cat > "$stage/INSTALL.md" <<'MDEOF'
# Installing this bundle

On a minimal **Ubuntu 24.04 LTS Server** install, with no desktop:

```sh
sudo ./provision/vstos-provision
sudo reboot
```

That is the whole procedure. It installs the low-latency kernel, the audio
engine, the plugin host, the plugin library and FBKSuppressor, configures
realtime scheduling, and enables the session. After the reboot:

```sh
vstos-status
```

To build a bootable installer ISO instead, so a machine sets itself up
unattended:

```sh
./build/build-iso.sh
```

Read `README.md` first, and `docs/WING.md` before plugging the console in.
MDEOF

mkdir -p "$OUT"
tar -C "$work" -czf "$OUT/$name.tar.gz" "$name"
( cd "$OUT" && sha256sum "$name.tar.gz" > "$name.tar.gz.sha256" )

printf 'built %s (%s)\n' "$OUT/$name.tar.gz" "$(du -h "$OUT/$name.tar.gz" | cut -f1)"
