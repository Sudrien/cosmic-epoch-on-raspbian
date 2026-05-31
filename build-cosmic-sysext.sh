#!/usr/bin/env bash
#
# build-cosmic-sysext.sh
# ----------------------
# Build the COSMIC desktop environment from Rust source on Raspberry Pi OS
# (Debian 13 "Trixie", arm64) and install it as a systemd system extension.
#
# Why a sysext: everything COSMIC installs lands in a single overlay under
# /var/lib/extensions/cosmic-sysext. While merged it overlays /usr and /opt
# read-only; it never modifies your base packages. Disable it and the system
# is exactly as before -- so your Raspberry Pi OS HEVC/Moonlight stack
# (patched Mesa / FFmpeg / libdrm) is untouched. Clean to remove: one flag.
#
# Rust: prefers your DISTRO's rustc/cargo (your preference), but COSMIC has a
# minimum supported rustc (currently 1.93) and Debian Trixie ships 1.85 -- too
# old. So the script checks the compiler version up front and automatically
# switches to a rustup-managed stable toolchain if the distro one is too old,
# instead of failing hours into the build. Force rustup with --rustup. Either
# way the toolchain and -dev libraries are build-time only; they are NOT needed
# at runtime, so you can remove them afterwards (the runtime .so's stay).
#
# Usage:
#   ./build-cosmic-sysext.sh                 # build + install the sysext
#   ./build-cosmic-sysext.sh --rustup        # use a rustup stable toolchain
#   ./build-cosmic-sysext.sh --ref master    # build git master instead of latest release tag
#   ./build-cosmic-sysext.sh --build-dir DIR # where to clone/build (default: ~/Projects/cosmic-epoch)
#   ./build-cosmic-sysext.sh --uninstall     # disable + remove the sysext
#   ./build-cosmic-sysext.sh --remove-build-deps   # after a successful build, remove the apt -dev/build packages this script installed
#   ./build-cosmic-sysext.sh -y              # assume "yes" to prompts
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
REPO_URL="https://github.com/pop-os/cosmic-epoch"
EXT_NAME="cosmic-sysext"                       # MUST NOT be renamed (systemd matches on it)
EXT_DEST="/var/lib/extensions"
BUILD_DIR="${HOME}/Projects/cosmic-epoch"
REF=""                                         # empty => latest epoch-* tag; or "master"; or a specific tag
USE_RUSTUP=0
REQUIRED_RUSTC="1.93"                           # COSMIC's current minimum rustc; bump if upstream raises its MSRV
DO_UNINSTALL=0
REMOVE_BUILD_DEPS=0
ASSUME_YES=0

# Required build dependencies (from the cosmic-epoch README), minus rust/just
# which we handle separately so we can honour system-vs-rustup choice.
REQUIRED_PKGS=(
  build-essential dbus git
  libdbus-1-dev libdisplay-info-dev libflatpak-dev libglvnd-dev
  libgstreamer-plugins-base1.0-dev libgstreamer1.0-dev
  libinput-dev libpam0g-dev libpixman-1-dev libseat-dev libssl-dev
  libwayland-dev libxkbcommon-dev udev
)
# Optional but recommended (lld/mold speed up linking a lot on a Pi).
OPTIONAL_PKGS=(
  libclang-dev libexpat1-dev libfontconfig-dev libfreetype-dev
  libgbm-dev libpipewire-0.3-dev libpulse-dev libsystemd-dev lld mold
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

# version_ge A B  -> true if version A >= version B
version_ge() { [[ "$1" == "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" ]]; }

confirm() {
  [[ "$ASSUME_YES" -eq 1 ]] && return 0
  read -r -p "$1 [y/N] " ans
  [[ "$ans" == "y" || "$ans" == "Y" ]]
}

SUDO=""
if [[ "${EUID}" -ne 0 ]]; then
  command -v sudo >/dev/null 2>&1 || die "Need root or sudo for apt / systemd steps."
  SUDO="sudo"
fi

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --rustup)            USE_RUSTUP=1 ;;
    --uninstall)         DO_UNINSTALL=1 ;;
    --remove-build-deps) REMOVE_BUILD_DEPS=1 ;;
    --ref)               REF="${2:?--ref needs a value}"; shift ;;
    --build-dir)         BUILD_DIR="${2:?--build-dir needs a value}"; shift ;;
    -y|--yes)            ASSUME_YES=1 ;;
    -h|--help)           grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)                   die "Unknown argument: $1 (try --help)" ;;
  esac
  shift
done

# ---------------------------------------------------------------------------
# Uninstall mode
# ---------------------------------------------------------------------------
uninstall() {
  log "Disabling systemd-sysext and removing the COSMIC extension..."
  $SUDO systemctl disable --now systemd-sysext 2>/dev/null || true
  $SUDO rm -rf "${EXT_DEST:?}/${EXT_NAME}"
  $SUDO systemd-sysext refresh 2>/dev/null || true
  log "Done. /usr and /opt are back to normal; base system unchanged."
  log "Build tree at ${BUILD_DIR} was left in place (delete it manually to reclaim disk)."
  exit 0
}
[[ "$DO_UNINSTALL" -eq 1 ]] && uninstall

# ---------------------------------------------------------------------------
# Sanity checks
# ---------------------------------------------------------------------------
[[ "${EUID}" -eq 0 ]] && warn "Running as root. Building Rust as root is not ideal; consider a normal user."

command -v systemd-sysext >/dev/null 2>&1 || die "systemd-sysext not found (need a recent systemd)."

if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  log "Host: ${PRETTY_NAME:-unknown} ($(uname -m))"
  case "${ID:-}:${ID_LIKE:-}" in
    *debian*|*raspbian*) : ;;
    *) warn "This script targets Debian/Raspberry Pi OS; package names may differ here." ;;
  esac
fi
[[ "$(dpkg --print-architecture 2>/dev/null || true)" == "arm64" ]] \
  || warn "Architecture is not arm64 -- fine on a Pi 5/500+ 64-bit image, unexpected otherwise."

mkdir -p "$(dirname "$BUILD_DIR")"
avail_kb="$(df -Pk "$(dirname "$BUILD_DIR")" | awk 'NR==2{print $4}')"
if [[ -n "${avail_kb:-}" && "$avail_kb" -lt 15000000 ]]; then
  warn "Less than ~15 GB free where the build will live. The target/ tree is large."
fi

# ---------------------------------------------------------------------------
# 1. Install build dependencies
# ---------------------------------------------------------------------------
log "Installing build dependencies via apt (this does not affect runtime libs you keep)..."
$SUDO apt-get update
$SUDO apt-get install -y "${REQUIRED_PKGS[@]}"
# Optional deps: install what's available, don't fail the run if one is missing.
$SUDO apt-get install -y "${OPTIONAL_PKGS[@]}" || warn "Some optional packages were unavailable; continuing."

# ---------------------------------------------------------------------------
# 2. Rust toolchain (system by default; rustup on request / fallback)
# ---------------------------------------------------------------------------
rustc_version() { rustc --version 2>/dev/null | awk '{print $2}'; }
rustc_meets_floor() {
  local rv; rv="$(rustc_version)"
  [[ -n "$rv" ]] && version_ge "$rv" "$REQUIRED_RUSTC"
}

setup_rust() {
  if [[ "$USE_RUSTUP" -eq 0 ]]; then
    if ! command -v cargo >/dev/null 2>&1 || ! command -v rustc >/dev/null 2>&1; then
      log "No system cargo/rustc found; installing distro Rust packages (rustc, cargo)..."
      $SUDO apt-get install -y rustc cargo || warn "Distro Rust unavailable; will use rustup."
    fi
    if command -v rustc >/dev/null 2>&1 && rustc_meets_floor; then
      log "Using system Rust: $(rustc --version)"
      return
    fi
    if command -v rustc >/dev/null 2>&1; then
      warn "System rustc $(rustc_version) is below COSMIC's required >= ${REQUIRED_RUSTC} (Debian Trixie ships 1.85)."
      warn "Automatically switching to a rustup-managed stable toolchain."
    fi
  fi

  log "Setting up a rustup-managed stable toolchain..."
  if ! command -v rustup >/dev/null 2>&1; then
    $SUDO apt-get install -y rustup || die "Could not install rustup via apt."
  fi
  rustup toolchain install stable
  rustup default stable
  export PATH="${HOME}/.cargo/bin:${PATH}"   # ensure rustup proxies win over /usr/bin
  hash -r 2>/dev/null || true
  rustc_meets_floor || die "rustup stable ($(rustc_version)) is still below ${REQUIRED_RUSTC}. Run 'rustup update', or bump REQUIRED_RUSTC if upstream changed."
  log "Using rustup Rust: $(rustc --version)"
}
setup_rust

# ---------------------------------------------------------------------------
# 3. 'just' (prefer distro package; else cargo install)
# ---------------------------------------------------------------------------
if ! command -v just >/dev/null 2>&1; then
  log "Installing 'just'..."
  if ! $SUDO apt-get install -y just; then
    warn "'just' not in apt; installing via cargo (this compiles it)."
    cargo install just
    export PATH="${HOME}/.cargo/bin:${PATH}"
  fi
fi
command -v just >/dev/null 2>&1 || die "'just' still not on PATH."
# Make sure cargo-installed binaries are reachable for the build.
export PATH="${HOME}/.cargo/bin:${PATH}"

# ---------------------------------------------------------------------------
# 4. Fetch source (pinned to the latest release tag by default for stability)
# ---------------------------------------------------------------------------
if [[ ! -d "$BUILD_DIR/.git" ]]; then
  log "Cloning cosmic-epoch into ${BUILD_DIR}..."
  git clone "$REPO_URL" "$BUILD_DIR"
fi
cd "$BUILD_DIR"
git fetch --tags --force origin

if [[ -z "$REF" ]]; then
  REF="$(git tag -l 'epoch-*' --sort=-v:refname | head -n1)"
  [[ -n "$REF" ]] || REF="master"
fi
log "Checking out: ${REF}"
git checkout --force "$REF"
log "Syncing submodules (27 components -- this pulls a lot)..."
git submodule update --init --recursive --force

# ---------------------------------------------------------------------------
# 5. Build the system extension
# ---------------------------------------------------------------------------
log "Building COSMIC. On a Pi 5 / 500+ this can take a few hours; let it run."
just sysext
[[ -d "$BUILD_DIR/$EXT_NAME" ]] || die "Expected ${BUILD_DIR}/${EXT_NAME} after 'just sysext' but it's missing."

# ---------------------------------------------------------------------------
# 6. Make the extension-release match Raspberry Pi OS regardless of build host
#    (ID=_any tells systemd to merge on any OS, avoiding "does not match host").
# ---------------------------------------------------------------------------
REL_FILE="$BUILD_DIR/$EXT_NAME/usr/lib/extension-release.d/extension-release.${EXT_NAME}"
if [[ -f "$REL_FILE" ]]; then
  if grep -q '^ID=' "$REL_FILE"; then
    sed -i 's/^ID=.*/ID=_any/' "$REL_FILE"
  else
    printf 'ID=_any\n' >> "$REL_FILE"
  fi
  log "Patched extension-release: ID=_any"
else
  warn "extension-release file not found where expected; sysext may refuse to merge."
fi

# ---------------------------------------------------------------------------
# 7. Install + activate
# ---------------------------------------------------------------------------
log "Installing the extension to ${EXT_DEST}/${EXT_NAME}..."
$SUDO mkdir -p "$EXT_DEST"
$SUDO rm -rf "${EXT_DEST:?}/${EXT_NAME}"
$SUDO cp -a "$BUILD_DIR/$EXT_NAME" "$EXT_DEST/"

log "Enabling systemd-sysext..."
$SUDO systemctl enable --now systemd-sysext
$SUDO systemd-sysext refresh
$SUDO systemd-sysext status || true

if [[ -e /usr/share/wayland-sessions/cosmic.desktop ]]; then
  log "COSMIC session entry is present at /usr/share/wayland-sessions/cosmic.desktop."
else
  warn "No cosmic.desktop session entry visible yet -- check 'systemd-sysext status' and that the merge succeeded."
fi

# ---------------------------------------------------------------------------
# 8. Optional: remove the apt build deps (runtime libs are kept)
# ---------------------------------------------------------------------------
if [[ "$REMOVE_BUILD_DEPS" -eq 1 ]]; then
  if confirm "Remove the -dev/build apt packages this script installed? (runtime .so's stay)"; then
    log "Removing build-only packages..."
    $SUDO apt-get remove -y "${REQUIRED_PKGS[@]}" "${OPTIONAL_PKGS[@]}" || warn "Some packages could not be removed."
    warn "Did NOT run 'apt autoremove' -- do that yourself only after confirming COSMIC still starts."
  fi
fi

cat <<EOF

$(log "Done.")
Next steps on Raspberry Pi OS:
  * Raspberry Pi OS often autologins to labwc with no session picker. To choose
    COSMIC you need a greeter that lists Wayland sessions: either disable
    autologin (sudo raspi-config -> System -> Boot/Auto Login), or just start
    it from a TTY with:  cosmic-session
  * While the sysext is MERGED, /usr and /opt are read-only. Run
    'sudo systemctl disable --now systemd-sysext' before any apt install/upgrade,
    then re-enable afterwards.
  * Your Moonlight / HEVC stack is unaffected by this overlay. If Moonlight's
    hardware path misbehaves *inside* the COSMIC session, run it from a TTY
    outside the desktop -- decode lives in the kernel/FFmpeg layer, not the DE.

To remove COSMIC completely and restore the system:
  ./build-cosmic-sysext.sh --uninstall
EOF
