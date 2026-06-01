#!/usr/bin/env bash
#
# build-cosmic-sysext.sh
# ----------------------
# Build the COSMIC desktop environment from Rust source on Raspberry Pi OS
# (Debian 13 "Trixie", arm64) and install it -- either as a systemd system
# extension (the default) or directly onto the root filesystem (--no-sysext).
#
# Why a sysext (default): everything COSMIC installs lands in a single overlay
# under /var/lib/extensions/cosmic-sysext. While merged it overlays /usr and
# /opt read-only; it never modifies your base packages. Disable it and the
# system is exactly as before -- so your Raspberry Pi OS HEVC/Moonlight stack
# (patched Mesa / FFmpeg / libdrm) is untouched. Clean to remove: one flag.
#
# --no-sysext: if you would rather have a permanent, always-on install, this
# copies the built tree straight into /usr (and /opt) on the real filesystem.
# It overwrites / shadows base-system files in place and /usr stays writable as
# usual. A raw install is NOT as clean as a sysext, but the install now records
# a manifest (and backs up any file it overwrites) under /var/lib/cosmic-sysext,
# so --uninstall can make a best-effort reversal: restore the files it clobbered
# and delete the ones it added. The sysext is the default; raw is the option.
#
# Patches applied to the build (BOTH install modes):
#   * start-cosmic logging: redirects the session bootstrap's stdout/stderr to
#     /tmp/cosmic-session-<user>.log with xtrace, so black-screen / early-exit
#     failures leave a trace. /tmp stays writable even under a merged sysext.
#   * polkit agent masking: Raspberry Pi OS autostarts lxpolkit (LXDE) and
#     polkit-mate; COSMIC ships its own agent and the extras error out. We ship
#     Hidden=true shadow .desktop files under /usr and have start-cosmic
#     prepend that dir to XDG_CONFIG_DIRS, so the masking applies ONLY inside
#     COSMIC and (under a sysext) vanishes when the extension is switched off.
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
#   ./build-cosmic-sysext.sh                     # build + install the sysext (default)
#   ./build-cosmic-sysext.sh --no-sysext         # build + install straight into / (tracked, see --uninstall)
#   ./build-cosmic-sysext.sh --install-only      # (re)apply patches + install a PRE-BUILT tree; no fetch, no rebuild
#   ./build-cosmic-sysext.sh --rustup            # use a rustup stable toolchain
#   ./build-cosmic-sysext.sh --ref master        # build git master instead of latest release tag
#   ./build-cosmic-sysext.sh --build-dir DIR     # where to clone/build (default: ~/Projects/cosmic-epoch)
#   ./build-cosmic-sysext.sh --uninstall         # remove COSMIC: drop the sysext, AND/OR reverse a raw install via its manifest
#   ./build-cosmic-sysext.sh --remove-build-deps # after a successful build, remove the apt -dev/build packages this script installed
#   ./build-cosmic-sysext.sh -y                  # assume "yes" to prompts
#
# --install-only and --no-sysext combine (reinstall a pre-built tree to the raw
# filesystem). --install-only requires an existing build at
# <build-dir>/cosmic-sysext -- run a normal build first.
#
# --uninstall auto-detects what is present: it removes the sysext if one is
# installed and reverses a raw install if a manifest exists, so you do not need
# to remember which mode you used.
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
REPO_URL="https://github.com/pop-os/cosmic-epoch"
EXT_NAME="cosmic-sysext"            # 'just sysext' staging-tree name AND the sysext name (do NOT rename for sysext installs)
EXT_DEST="/var/lib/extensions"
STATE_DIR="/var/lib/cosmic-sysext"  # persists the raw-install manifest + backups (outside the build tree)
BUILD_DIR="${HOME}/Projects/cosmic-epoch"
REF=""                              # empty => latest epoch-* tag; or "master"; or a specific tag
USE_RUSTUP=0
REQUIRED_RUSTC="1.93"               # COSMIC's current minimum rustc; bump if upstream raises its MSRV
DO_UNINSTALL=0
REMOVE_BUILD_DEPS=0
ASSUME_YES=0
USE_SYSEXT=1                        # 0 with --no-sysext => install onto the raw filesystem
INSTALL_ONLY=0                      # 1 with --install-only => skip fetch + build; patch + install only

# Directory (under /usr/share) holding the Hidden=true autostart shadow files.
AUTOSTART_OVR_NAME="cosmic-sysext-autostart"

# Required build dependencies (from the cosmic-epoch README), minus rust/just
# which we handle separately so we can honour system-vs-rustup choice.
REQUIRED_PKGS=(
  build-essential dbus git git-lfs
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

# version_ge A B -> true if version A >= version B
version_ge() { [[ "$1" == "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" ]]; }

confirm() {
  [[ "$ASSUME_YES" -eq 1 ]] && return 0
  read -r -p "$1 [y/N] " ans
  [[ "$ans" == "y" || "$ans" == "Y" ]]
}

# Refresh system caches so newly added / removed binaries, .so's, gschemas and
# desktop entries register. All best-effort; never fatal.
refresh_caches() {
  $SUDO ldconfig || true
  if command -v glib-compile-schemas >/dev/null 2>&1 && [[ -d /usr/share/glib-2.0/schemas ]]; then
    $SUDO glib-compile-schemas /usr/share/glib-2.0/schemas || true
  fi
  if command -v update-desktop-database >/dev/null 2>&1 && [[ -d /usr/share/applications ]]; then
    $SUDO update-desktop-database /usr/share/applications 2>/dev/null || true
  fi
}

SUDO=""
if [[ "${EUID}" -ne 0 ]]; then
  command -v sudo >/dev/null 2>&1 || die "Need root or sudo for apt / systemd / install steps."
  SUDO="sudo"
fi

# ---------------------------------------------------------------------------
# Patch helpers (operate on the staging tree at $BUILD_DIR/$EXT_NAME; both
# install modes copy from there, so patching happens in exactly one place).
# ---------------------------------------------------------------------------

# Insert a block immediately after the shebang of a script, guarded by a marker
# so it is idempotent across rebuilds. $1=file  $2=marker  $3=block-text
insert_after_shebang() {
  local file="$1" marker="$2" block="$3" tmp
  if grep -q "$marker" "$file"; then
    return 1   # already patched
  fi
  tmp="$(mktemp)"
  {
    head -n1 "$file"          # keep original shebang as line 1
    printf '%s\n' "$block"
    tail -n +2 "$file"        # rest of the original script
  } > "$tmp"
  chmod --reference="$file" "$tmp"   # preserve mode (0755)
  mv "$tmp" "$file"
  return 0
}

patch_start_cosmic_logging() {
  local f="$BUILD_DIR/$EXT_NAME/usr/bin/start-cosmic"
  [[ -f "$f" ]] || { warn "start-cosmic not found at $f; cannot add startup logging."; return; }
  if insert_after_shebang "$f" 'COSMIC-DEBUG-LOG' \
'# COSMIC-DEBUG-LOG: added by build-cosmic-sysext.sh
#set -e
exec >"/tmp/cosmic-session-$(id -un).log" 2>&1
set -x
set -e'; then
    log "Patched start-cosmic: logging to /tmp/cosmic-session-<user>.log (marker: COSMIC-DEBUG-LOG)."
  else
    log "start-cosmic already has the logging patch; skipping."
  fi
}

patch_autostart_overrides() {
  local ovr_dir="$BUILD_DIR/$EXT_NAME/usr/share/$AUTOSTART_OVR_NAME/autostart"
  local f="$BUILD_DIR/$EXT_NAME/usr/bin/start-cosmic"
  local app

  mkdir -p "$ovr_dir"
  for app in lxpolkit polkit-mate-authentication-agent-1; do
    cat > "$ovr_dir/${app}.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=${app} (disabled in COSMIC by ${EXT_NAME})
Hidden=true
NoDisplay=true
NotShowIn=COSMIC;
EOF
  done
  log "Wrote autostart shadow files: lxpolkit, polkit-mate-authentication-agent-1"

  [[ -f "$f" ]] || { warn "start-cosmic not found; cannot wire up XDG_CONFIG_DIRS override."; return; }
  if insert_after_shebang "$f" 'COSMIC-AUTOSTART-OVERRIDE' \
"# COSMIC-AUTOSTART-OVERRIDE: added by build-cosmic-sysext.sh
# Mask conflicting polkit agents (lxpolkit / polkit-mate) in COSMIC only.
export XDG_CONFIG_DIRS=\"/usr/share/$AUTOSTART_OVR_NAME:\${XDG_CONFIG_DIRS:-/etc/xdg}\""; then
    log "Patched start-cosmic to prepend the autostart override dir."
  else
    log "start-cosmic already prepends the autostart override dir; skipping."
  fi
}

apply_patches() {
  [[ -d "$BUILD_DIR/$EXT_NAME" ]] || die "Build tree ${BUILD_DIR}/${EXT_NAME} is missing; cannot patch."
  log "Applying patches to the built tree..."
  patch_start_cosmic_logging
  patch_autostart_overrides
}

# ---------------------------------------------------------------------------
# Raw-install helpers (manifest + backup, so --uninstall can reverse it)
#
# Layout under $STATE_DIR:
#   raw-install.files        every file/symlink target path we placed under /
#   raw-install.newdirs      directories WE created (rmdir'd if empty on remove)
#   raw-install.preexisting  targets that already existed (we overwrote them)
#   raw-install.info         ref / date / build-dir, for reference
#   backup/<path>            originals of every overwritten target (for restore)
#
# Manifests are cumulative across reinstalls: a file we installed last time is
# treated as ours (not a distro original), and a real original's backup is
# never clobbered by a second install.
# ---------------------------------------------------------------------------

# Enumerate staging-tree members (relative to $1), excluding sysext metadata.
# $2 = "files" (non-dirs) or "dirs". Prints absolute target paths under /.
_stage_list() {
  local src="$1" kind="$2"
  if [[ "$kind" == "dirs" ]]; then
    ( cd "$src" && find . -path './usr/lib/extension-release.d' -prune -o -type d -print )
  else
    ( cd "$src" && find . -path './usr/lib/extension-release.d' -prune -o ! -type d -print )
  fi | sed 's|^\.||' | sed '/^$/d' | sort -u
}

raw_install() {
  local src="$BUILD_DIR/$EXT_NAME"
  local files_tmp dirs_tmp pre_tmp newdirs_tmp prevf_tmp rel t backed=0

  log "Installing COSMIC directly onto the root filesystem (no sysext)..."
  warn "This copies COSMIC's files permanently into /usr (and /opt) and shadows base"
  warn "files in place. A manifest + backups will be written to $STATE_DIR so that"
  warn "--uninstall can attempt to reverse it, but a raw install is still less clean"
  warn "than the sysext (a distro update after install can defeat the reversal)."
  if ! confirm "Proceed with the raw filesystem install into / ?"; then
    die "Aborted before raw install; nothing was copied."
  fi

  files_tmp="$(mktemp)"; dirs_tmp="$(mktemp)"
  pre_tmp="$(mktemp)";   newdirs_tmp="$(mktemp)"; prevf_tmp="$(mktemp)"

  _stage_list "$src" files > "$files_tmp"
  _stage_list "$src" dirs  > "$dirs_tmp"

  # Previously-installed file set (if any): those are OURS, not distro originals.
  if [[ -f "$STATE_DIR/raw-install.files" ]]; then
    sort -u "$STATE_DIR/raw-install.files" > "$prevf_tmp"
  fi

  log "Backing up any base-system files this install would overwrite..."
  $SUDO mkdir -p "$STATE_DIR/backup"
  while IFS= read -r t; do
    [[ -z "$t" ]] && continue
    if [[ -e "$t" || -L "$t" ]]; then
      # Skip files we ourselves installed in a previous run.
      grep -qxF "$t" "$prevf_tmp" && continue
      echo "$t" >> "$pre_tmp"
      # Never clobber an existing backup (preserve the true original).
      if [[ ! -e "$STATE_DIR/backup$t" && ! -L "$STATE_DIR/backup$t" ]]; then
        $SUDO mkdir -p "$STATE_DIR/backup$(dirname "$t")"
        $SUDO cp -a "$t" "$STATE_DIR/backup$t"
        backed=$((backed + 1))
      fi
    fi
  done < "$files_tmp"

  # Directories we are creating (don't exist yet) -> candidates for rmdir later.
  while IFS= read -r t; do
    [[ -z "$t" || "$t" == "/" ]] && continue
    [[ -d "$t" ]] || echo "$t" >> "$newdirs_tmp"
  done < "$dirs_tmp"

  # Extract into / via tar so files land ROOT-owned (cp -a would keep the build
  # user's ownership) and sysext-only metadata is excluded. tar is always present.
  log "Copying tree into / (root-owned, sysext metadata excluded)..."
  ( cd "$src" \
      && tar -cf - --owner=0 --group=0 \
           --exclude='./usr/lib/extension-release.d' \
           --exclude='./usr/lib/extension-release.d/*' . ) \
    | $SUDO tar -xpf - -C /

  # Merge with any prior manifest so removal stays complete across reinstalls.
  [[ -f "$STATE_DIR/raw-install.preexisting" ]] && cat "$STATE_DIR/raw-install.preexisting" >> "$pre_tmp"
  [[ -f "$STATE_DIR/raw-install.newdirs"     ]] && cat "$STATE_DIR/raw-install.newdirs"     >> "$newdirs_tmp"
  sort -u "$pre_tmp"     -o "$pre_tmp"
  sort -u "$newdirs_tmp" -o "$newdirs_tmp"

  $SUDO mkdir -p "$STATE_DIR"
  $SUDO cp "$files_tmp"   "$STATE_DIR/raw-install.files"
  $SUDO cp "$pre_tmp"     "$STATE_DIR/raw-install.preexisting"
  $SUDO cp "$newdirs_tmp" "$STATE_DIR/raw-install.newdirs"
  printf 'ref=%s\ndate=%s\nbuild_dir=%s\n' "${REF:-unknown}" "$(date -Is)" "$BUILD_DIR" \
    | $SUDO tee "$STATE_DIR/raw-install.info" >/dev/null

  rm -f "$files_tmp" "$dirs_tmp" "$pre_tmp" "$newdirs_tmp" "$prevf_tmp"

  refresh_caches
  log "Raw install complete. Manifest: $STATE_DIR ($(wc -l < "$STATE_DIR/raw-install.files") files, ${backed} backed up)."
}

uninstall_raw() {
  local files="$STATE_DIR/raw-install.files"
  local pre="$STATE_DIR/raw-install.preexisting"
  local newdirs="$STATE_DIR/raw-install.newdirs"
  local t

  if [[ ! -f "$files" ]]; then
    return 1   # no raw install recorded
  fi

  warn "About to reverse a RAW COSMIC install using $STATE_DIR."
  warn "Files COSMIC ADDED will be deleted; files it OVERWROTE will be restored from"
  warn "backup. Caveat: distro packages updated AFTER the install may be reverted to"
  warn "their pre-install state, or partially removed -- verify afterwards."
  if ! confirm "Proceed with raw uninstall?"; then
    warn "Raw uninstall declined; left in place."
    return 0
  fi

  # 1. Restore originals we backed up.
  if [[ -s "$pre" ]]; then
    log "Restoring $(wc -l < "$pre") overwritten file(s) from backup..."
    while IFS= read -r t; do
      [[ -z "$t" ]] && continue
      if [[ -e "$STATE_DIR/backup$t" || -L "$STATE_DIR/backup$t" ]]; then
        $SUDO mkdir -p "$(dirname "$t")"
        $SUDO cp -a "$STATE_DIR/backup$t" "$t"
      fi
    done < "$pre"
  fi

  # 2. Delete files we added (in files list, not in preexisting list).
  log "Removing COSMIC-added files..."
  comm -23 <(sort -u "$files") <(sort -u "$pre" 2>/dev/null || true) \
    | while IFS= read -r t; do
        [[ -z "$t" ]] && continue
        $SUDO rm -f "$t"
      done

  # 3. Remove now-empty directories we created (deepest first; never force).
  if [[ -f "$newdirs" ]]; then
    sort -r "$newdirs" | while IFS= read -r t; do
      [[ -z "$t" || "$t" == "/" ]] && continue
      $SUDO rmdir "$t" 2>/dev/null || true
    done
  fi

  refresh_caches
  $SUDO rm -rf "$STATE_DIR"
  log "Raw uninstall complete (manifest + backups removed)."
  return 0
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --rustup)            USE_RUSTUP=1 ;;
    --no-sysext)         USE_SYSEXT=0 ;;
    --install-only)      INSTALL_ONLY=1 ;;
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
# Uninstall mode (auto-detects sysext and/or raw install)
# ---------------------------------------------------------------------------
uninstall() {
  local did=0
  if [[ -d "$EXT_DEST/$EXT_NAME" ]]; then
    log "Disabling systemd-sysext and removing the COSMIC extension..."
    $SUDO systemctl disable --now systemd-sysext 2>/dev/null || true
    $SUDO rm -rf "${EXT_DEST:?}/${EXT_NAME}"
    $SUDO systemd-sysext refresh 2>/dev/null || true
    log "Sysext removed; /usr and /opt are back to normal."
    did=1
  fi
  if [[ -f "$STATE_DIR/raw-install.files" ]]; then
    uninstall_raw && did=1
  fi
  if [[ "$did" -eq 0 ]]; then
    warn "Found neither a sysext at $EXT_DEST/$EXT_NAME nor a raw manifest at $STATE_DIR."
    warn "Nothing to uninstall."
  fi
  log "Build tree at ${BUILD_DIR} was left in place (delete it manually to reclaim disk)."
  exit 0
}
[[ "$DO_UNINSTALL" -eq 1 ]] && uninstall

# ---------------------------------------------------------------------------
# Sanity checks
# ---------------------------------------------------------------------------
[[ "${EUID}" -eq 0 ]] && warn "Running as root. Building Rust as root is not ideal; consider a normal user."

if [[ "$USE_SYSEXT" -eq 1 ]]; then
  command -v systemd-sysext >/dev/null 2>&1 \
    || die "systemd-sysext not found (need a recent systemd). Use --no-sysext to install onto the raw filesystem instead."
fi

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

if [[ "$INSTALL_ONLY" -eq 0 ]]; then
  mkdir -p "$(dirname "$BUILD_DIR")"
  avail_kb="$(df -Pk "$(dirname "$BUILD_DIR")" | awk 'NR==2{print $4}')"
  if [[ -n "${avail_kb:-}" && "$avail_kb" -lt 15000000 ]]; then
    warn "Less than ~15 GB free where the build will live. The target/ tree is large."
  fi
fi

# ===========================================================================
# BUILD  (skipped entirely with --install-only)
# ===========================================================================
if [[ "$INSTALL_ONLY" -eq 0 ]]; then

  # -------------------------------------------------------------------------
  # 1. Install build dependencies
  # -------------------------------------------------------------------------
  log "Installing build dependencies via apt (this does not affect runtime libs you keep)..."
  $SUDO apt-get update
  $SUDO apt-get install -y "${REQUIRED_PKGS[@]}"
  # Optional deps: install what's available, don't fail the run if one is missing.
  $SUDO apt-get install -y "${OPTIONAL_PKGS[@]}" || warn "Some optional packages were unavailable; continuing."

  # -------------------------------------------------------------------------
  # 2. Rust toolchain (system by default; rustup on request / fallback)
  # -------------------------------------------------------------------------
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

  # -------------------------------------------------------------------------
  # 3. 'just' (prefer distro package; else cargo install)
  # -------------------------------------------------------------------------
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

  # -------------------------------------------------------------------------
  # 4. Fetch source (pinned to the latest release tag by default for stability)
  # -------------------------------------------------------------------------
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
  git submodule foreach git lfs pull

  # -------------------------------------------------------------------------
  # 5. Build the system extension tree
  # -------------------------------------------------------------------------
  log "Building COSMIC. On a Pi 5 / 500+ this can take a few hours; let it run."
  just sysext
  [[ -d "$BUILD_DIR/$EXT_NAME" ]] || die "Expected ${BUILD_DIR}/${EXT_NAME} after 'just sysext' but it's missing."

else
  log "--install-only: skipping apt deps, toolchain setup, source fetch, and build."
  [[ -d "$BUILD_DIR/$EXT_NAME" ]] \
    || die "--install-only needs a pre-built tree at ${BUILD_DIR}/${EXT_NAME}. Run a normal build first."
fi

# ===========================================================================
# PATCH  (always, for both fresh builds and --install-only; idempotent)
# ===========================================================================
apply_patches

# ===========================================================================
# INSTALL
# ===========================================================================
if [[ "$USE_SYSEXT" -eq 1 ]]; then

  # -------------------------------------------------------------------------
  # 6. Make the extension-release match Raspberry Pi OS regardless of build host
  #    (ID=_any tells systemd to merge on any OS, avoiding "does not match host").
  # -------------------------------------------------------------------------
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

  # -------------------------------------------------------------------------
  # 7. Install + activate the sysext
  # -------------------------------------------------------------------------
  log "Installing the extension to ${EXT_DEST}/${EXT_NAME}..."
  $SUDO mkdir -p "$EXT_DEST"
  $SUDO rm -rf "${EXT_DEST:?}/${EXT_NAME}"
  $SUDO cp -a "$BUILD_DIR/$EXT_NAME" "$EXT_DEST/"

  log "Enabling systemd-sysext..."
  $SUDO systemctl enable --now systemd-sysext
  $SUDO systemd-sysext refresh
  $SUDO systemd-sysext status || true

else
  # -------------------------------------------------------------------------
  # 7. Raw filesystem install (no sysext) -- tracked via manifest + backups.
  # -------------------------------------------------------------------------
  raw_install
fi

# ---------------------------------------------------------------------------
# Session-entry sanity (applies to both modes)
# ---------------------------------------------------------------------------
if [[ -e /usr/share/wayland-sessions/cosmic.desktop ]]; then
  log "COSMIC session entry is present at /usr/share/wayland-sessions/cosmic.desktop."
else
  warn "No cosmic.desktop session entry visible yet -- check that the install/merge succeeded."
fi

# ---------------------------------------------------------------------------
# 8. Optional: remove the apt build deps (runtime libs are kept)
# ---------------------------------------------------------------------------
if [[ "$REMOVE_BUILD_DEPS" -eq 1 ]]; then
  [[ "$INSTALL_ONLY" -eq 1 ]] && warn "--install-only did not install build deps this run; removing them anyway as requested."
  if confirm "Remove the -dev/build apt packages this script installs? (runtime .so's stay)"; then
    log "Removing build-only packages..."
    $SUDO apt-get remove -y "${REQUIRED_PKGS[@]}" "${OPTIONAL_PKGS[@]}" || warn "Some packages could not be removed."
    warn "Did NOT run 'apt autoremove' -- do that yourself only after confirming COSMIC still starts."
  fi
fi

# ---------------------------------------------------------------------------
# Epilogue
# ---------------------------------------------------------------------------
log "Done."
echo
echo "Next steps on Raspberry Pi OS:"
echo
echo "  * Raspberry Pi OS often autologins to labwc with no session picker. To choose"
echo "    COSMIC you need a greeter that lists Wayland sessions: either disable autologin"
echo "    (sudo raspi-config -> System -> Boot/Auto Login), or just start it from a TTY"
echo "    with:  cosmic-session"
echo
echo "  * Startup log lives at /tmp/cosmic-session-<user>.log (cleared on reboot)."
echo
echo "  * Conflicting polkit agents (lxpolkit / polkit-mate) are masked ONLY inside COSMIC"
echo "    via XDG_CONFIG_DIRS; your other desktop sessions are unaffected."
echo
if [[ "$USE_SYSEXT" -eq 1 ]]; then
  echo "  * While the sysext is MERGED, /usr and /opt are read-only. Run"
  echo "        sudo systemctl disable --now systemd-sysext"
  echo "    before any apt install/upgrade, then re-enable afterwards."
  echo
  echo "  * To remove COSMIC completely and restore the system:"
  echo "        $0 --uninstall"
else
  echo "  * This was a RAW install: COSMIC files now live permanently in /usr (writable as"
  echo "    usual). A manifest + backups were recorded under $STATE_DIR."
  echo
  echo "  * To attempt to reverse it (restore overwritten files, delete added ones):"
  echo "        $0 --uninstall"
  echo "    Best-effort: a distro update made after this install can defeat the reversal."
fi
echo
echo "  * Your Moonlight / HEVC stack is unaffected by COSMIC. If Moonlight's hardware path"
echo "    misbehaves *inside* the COSMIC session, run it from a TTY outside the desktop --"
echo "    decode lives in the kernel/FFmpeg layer, not the DE."
