#!/usr/bin/env bash
# Install build toolchains inside the Ubuntu LXC: C/C++ compiler stack
# (build-essential), Go, and pkg-config.
#
# `build-essential` is Debian/Ubuntu's meta-package for the standard
# native build chain — gcc, g++, make, libc-dev, dpkg-dev. It's what
# every "./configure && make" or `go build` with cgo expects to find.
#
# Go is installed from Ubuntu's repo (`golang-go`). On Noble that
# tracks the latest stable Go fairly closely; if you need a newer
# version than apt offers, install via tarball from go.dev/dl/ or use
# a version manager like `g` (https://github.com/stefanmaric/g) — out
# of scope here.
#
# Idempotent: each package is installed only if missing.

set -euo pipefail

log()  { printf '\033[1;34m[install-toolchains]\033[0m %s\n' "$*"; }

# ---- pick what's missing ---------------------------------------------------
to_install=()
command -v gcc        >/dev/null 2>&1 || to_install+=(build-essential)
command -v go         >/dev/null 2>&1 || to_install+=(golang-go)
command -v pkg-config >/dev/null 2>&1 || to_install+=(pkg-config)

if [ "${#to_install[@]}" -eq 0 ]; then
    log "build-essential, go, pkg-config already installed — nothing to do"
else
    log "installing: ${to_install[*]}"
    sudo apt-get update -y
    sudo apt-get install -y "${to_install[@]}"
fi

# ---- summary ---------------------------------------------------------------
log "versions:"
gcc --version 2>/dev/null | head -1 || echo "  gcc:        not found"
make --version 2>/dev/null | head -1 || echo "  make:       not found"
go version 2>/dev/null               || echo "  go:         not found"
pkg-config --version 2>/dev/null \
    | awk '{print "  pkg-config: " $0}'
