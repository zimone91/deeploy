#!/usr/bin/env bash
# ============================================================================
# DeePloy — lib/toolchain.sh   (Phase 4: toolchain / build)
# rustup -> anza CLI -> build jito-solana @ $JITO_TAG with LTO + target-cpu, move
# to releases/$TAG, repoint active_release (keeping the previous release for
# rollback), setcap, verify.
#
# PUBLIC BUILD IS VANILLA. A non-vanilla build is produced ONLY if an optional
# patch is present under private/ (git-ignored). The seam is generic: "if a
# patch exists, git apply --check it; on success apply, else loud-skip and build
# vanilla." Nothing here names that patch, reveals its purpose, or hardcodes the
# mostly_confirmed_threshold value — that value rides with the overlay (a file
# in the overlay dir, or DEEPLOY_MOSTLY_CONFIRMED_THRESHOLD) and is written ONLY
# when the patch applied.
#
# Requires: common.sh + constants.sh sourced (the latter carries the version
# floor DEEPLOY_MIN_JITO_TAG). Heavy/network steps honor --dry-run; paths are
# env-overridable so tests never touch the real toolchain.
# ============================================================================

[[ -n "${_DEEPLOY_TOOLCHAIN_SOURCED:-}" ]] && return 0
_DEEPLOY_TOOLCHAIN_SOURCED=1

SOLANA_INSTALL_DIR="${SOLANA_INSTALL_DIR:-$HOME/.local/share/solana/install}"
RELEASES_DIR="$SOLANA_INSTALL_DIR/releases"
ACTIVE_RELEASE="$SOLANA_INSTALL_DIR/active_release"
JITO_SRC="${JITO_SRC:-$HOME/jito-solana}"
JITO_REPO="${JITO_REPO:-https://github.com/jito-foundation/jito-solana.git}"
RUST_TARGET_CPU="${RUST_TARGET_CPU:-native}"
# Generic optional overlay directory (git-ignored). No specific filename here.
# Anchored to the CHECKOUT (DEEPLOY_DIR, set by deeploy.sh before sourcing), NOT
# the cwd: a run started from any other directory used to resolve "private"
# relative to $PWD, silently miss the overlay, and build VANILLA (R10).
OVERLAY_DIR="${DEEPLOY_OVERLAY_DIR:-${DEEPLOY_DIR:-.}/private}"
# Root threshold path (overridable for tests). The per-home one comes from state.
MOSTLY_THRESHOLD_ROOT="${MOSTLY_THRESHOLD_ROOT:-/mostly_confirmed_threshold}"

TOOLCHAIN_BUILD_DEPS=(
    git curl build-essential pkg-config libssl-dev llvm-dev libclang-dev
    libudev-dev clang protobuf-compiler lld ca-certificates unzip
)

# The 5 capabilities the validator needs (matches solana.service AmbientCapabilities).
TOOLCHAIN_CAPS="cap_net_raw,cap_net_admin,cap_bpf,cap_perfmon,cap_sys_nice"

# scripts/cargo-install-all.sh flags (v4.0.0-jito mainnet recipe):
#   --release-with-lto         build with the injected LTO profile
#   --no-build-platform-tools  skip the SBF platform-tools build (required on v4.0.0)
TOOLCHAIN_BUILD_FLAGS=(--release-with-lto --no-build-platform-tools)

_OVERLAY_APPLIED=0

# --- config ------------------------------------------------------------------
toolchain_resolve_config() {
    if [[ -z "${JITO_TAG:-}" ]]; then
        ask "jito-solana build tag (e.g. v3.1.14-jito)" "${JITO_TAG:-}"
        JITO_TAG="$REPLY"
    fi
    [[ -n "$JITO_TAG" ]] || fail "JITO_TAG is required"
    [[ "$JITO_TAG" == *-jito ]] || warn "JITO_TAG '$JITO_TAG' does not end in -jito — double-check it"
    # Version floor, checked BEFORE the 30-90 minute build (this is the whole
    # point): the generated validator.sh passes flags that do not exist on older
    # clients, so an old tag builds fine and then refuses to start.
    local why
    why="$(deeploy_tag_floor_problem "$JITO_TAG")" \
        || fail "refusing to build '${JITO_TAG}': ${why}. DeePloy generates a validator.sh that passes --no-xdp and --poh-pinned-cpu-core, and both first exist in ${DEEPLOY_MIN_JITO_TAG} — an older client rejects the argv and never starts, after the entire build. Set JITO_TAG to ${DEEPLOY_MIN_JITO_TAG} or newer."
    state_set jito_tag "$JITO_TAG"
}

# --- dependencies / rust / anza CLI (network; --dry-run safe) -----------------
toolchain_deps() {
    step "Build dependencies"
    export DEBIAN_FRONTEND=noninteractive
    run apt-get update
    run apt-get install -y "${TOOLCHAIN_BUILD_DEPS[@]}"
}

toolchain_rust() {
    step "Rust toolchain (rustup)"
    if have rustup; then
        run rustup update
    elif is_dry_run; then
        info "${C_DIM}[dry-run]${C_NC} would install rustup, then rustup default stable"
    else
        local inst; inst=$(_mktemp)
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs -o "$inst"
        # File form: args after the script go to rustup-init itself. Pass ONLY -y
        # (non-interactive; default toolchain = stable). NOT `-s` (that is sh's
        # read-from-stdin flag, for the `curl | sh -s -- -y` PIPE form) and NOT a
        # leading `--` (in the pipe form `sh` eats the `--`; forwarding it here
        # would make rustup-init treat -y as an unexpected positional).
        sh "$inst" -y
        rm -f "$inst"
        ensure_cargo_env            # put the just-installed cargo/rustc on PATH for this run
        run rustup default stable
        run rustup update
    fi
}

toolchain_anza_cli() {
    local ver="${JITO_TAG%-jito}"     # anza release matching the jito base version
    step "anza CLI ${ver} (PATH + install scaffold)"
    if is_dry_run; then info "${C_DIM}[dry-run]${C_NC} would install anza CLI ${ver}"; return 0; fi
    local inst; inst=$(_mktemp)
    curl -sSfL "https://release.anza.xyz/${ver}/install" -o "$inst"
    sh "$inst"
    rm -f "$inst"
}

# --- fetch source ------------------------------------------------------------
toolchain_fetch_source() {
    step "Fetching jito-solana @ ${JITO_TAG}"
    [[ -d "$JITO_SRC" ]] && run rm -rf "$JITO_SRC"
    run git clone "$JITO_REPO" "$JITO_SRC"
    run git -C "$JITO_SRC" fetch --tags
    run git -C "$JITO_SRC" checkout "tags/${JITO_TAG}"
    run git -C "$JITO_SRC" submodule update --init --recursive
}

# --- THE OVERLAY SEAM (the only path to a non-vanilla build) -----------------
# Find an optional patch in the overlay dir without naming any specific file.
_toolchain_find_overlay() {
    local p
    for p in "$OVERLAY_DIR"/*.patch; do
        [[ -f "$p" ]] && { printf '%s' "$p"; return 0; }
    done
    return 1
}

toolchain_apply_overlay() {
    local repo="$JITO_SRC" patch abspatch
    _OVERLAY_APPLIED=0
    if ! patch=$(_toolchain_find_overlay); then
        info "No private overlay present — building VANILLA (public build)"
        return 0
    fi
    abspatch="$(cd "$(dirname "$patch")" && pwd)/$(basename "$patch")"
    # The git apply --check fork: apply ONLY if it cleanly applies to this tag.
    if git -C "$repo" apply --check "$abspatch" >/dev/null 2>&1; then
        run git -C "$repo" apply "$abspatch"
        _OVERLAY_APPLIED=1
        ok "Applied private overlay (clean git apply --check)"
    else
        warn "Private overlay does NOT apply to ${JITO_TAG} (tag drift) — SKIPPING it, building VANILLA"
    fi
}

# mostly_confirmed_threshold is written ONLY when the overlay applied, and its
# value is NEVER hardcoded here — it comes from the overlay (file or env).
toolchain_write_threshold() {
    [[ "$_OVERLAY_APPLIED" == "1" ]] || return 0
    local val=""
    if [[ -f "$OVERLAY_DIR/mostly_confirmed_threshold" ]]; then
        val="$(cat "$OVERLAY_DIR/mostly_confirmed_threshold")"
    elif [[ -n "${DEEPLOY_MOSTLY_CONFIRMED_THRESHOLD:-}" ]]; then
        val="$DEEPLOY_MOSTLY_CONFIRMED_THRESHOLD"
    fi
    if [[ -z "$val" ]]; then
        warn "Overlay applied but no threshold provided (overlay file or DEEPLOY_MOSTLY_CONFIRMED_THRESHOLD) — not writing it"
        return 0
    fi
    local home; home="$(state_get solana_home /root/solana)"
    write_file "$MOSTLY_THRESHOLD_ROOT" "${val}"$'\n'
    write_file "${home}/mostly_confirmed_threshold" "${val}"$'\n'
    ok "Wrote mostly_confirmed_threshold (rides with the private overlay)"
}

# --- LTO profile (inject if absent — version-drift proof) --------------------
toolchain_inject_lto_profile() {
    local cargo="${1:-$JITO_SRC/Cargo.toml}" tmp
    [[ -f "$cargo" ]] || { warn "Cargo.toml not found at $cargo"; return 0; }
    if grep -q '\[profile.release-with-lto\]' "$cargo"; then
        info "Cargo.toml already defines [profile.release-with-lto]"
        return 0
    fi
    tmp=$(_mktemp)
    { printf '[profile.release-with-lto]\ninherits = "release"\nlto = "fat"\ncodegen-units = 1\n\n'; cat "$cargo"; } >"$tmp"
    _commit "$cargo" "$tmp" "Cargo.toml: inject [profile.release-with-lto]"
}

# Teach scripts/cargo-install-all.sh the --release-with-lto flag (if it lacks it).
toolchain_patch_cargo_script() {
    local script="${1:-$JITO_SRC/scripts/cargo-install-all.sh}" branchfile tmp
    [[ -f "$script" ]] || { warn "cargo-install-all.sh not found at $script"; return 0; }
    if grep -q -- '--release-with-lto' "$script"; then
        info "cargo-install-all.sh already supports --release-with-lto"
        return 0
    fi
    branchfile=$(_mktemp)
    cat >"$branchfile" <<'BRANCH'
    elif [[ $1 = --release-with-lto ]]; then
      buildProfileArg='--profile release-with-lto'
      buildProfile='release-with-lto'
      shift
BRANCH
    tmp=$(_mktemp)
    # Insert the branch right after the existing release-with-debug assignment
    # block (the assignment line + its following line), mirroring the memo's sed.
    awk -v bf="$branchfile" '
        { print }
        /buildProfile=.*release-with-debug/ {
            if ((getline nxt) > 0) print nxt
            while ((getline line < bf) > 0) print line
            close(bf)
        }
    ' "$script" >"$tmp"
    rm -f "$branchfile"
    _commit "$script" "$tmp" "cargo-install-all.sh: +--release-with-lto"
}

# --- compile + install (keep previous release for rollback) ------------------
toolchain_compile() {
    local rustflags="-Clink-arg=-fuse-ld=lld -Ctarget-cpu=${RUST_TARGET_CPU}"
    step "Compiling jito-solana ${JITO_TAG} (LTO, target-cpu=${RUST_TARGET_CPU}) — long"
    if is_dry_run; then
        info "${C_DIM}[dry-run]${C_NC} would run: RUSTFLAGS=\"${rustflags}\" ./scripts/cargo-install-all.sh ${TOOLCHAIN_BUILD_FLAGS[*]} ."
        return 0
    fi
    ensure_cargo_env            # resolve cargo even on --only 4 / a resume where toolchain_rust was skipped
    ( cd "$JITO_SRC" && RUSTFLAGS="$rustflags" ./scripts/cargo-install-all.sh "${TOOLCHAIN_BUILD_FLAGS[@]}" . )
}

# Move freshly built binaries into releases/$TAG and repoint active_release.
# NEVER deletes other releases — the previous one is kept for `upgrade --rollback`.
toolchain_install_release() {
    local tag="$JITO_TAG" srcbin="${1:-$JITO_SRC/bin}" dest="$RELEASES_DIR/${JITO_TAG}" prev
    step "Installing release ${tag} (keeping previous for rollback)"
    run mkdir -p "$dest/bin"
    run mv "$srcbin"/* "$dest/bin/"
    if [[ -L "$ACTIVE_RELEASE" ]]; then
        prev="$(readlink "$ACTIVE_RELEASE")"
        if [[ "$prev" != "$dest" ]]; then
            state_set previous_release "$prev"
            info "Previous release kept for rollback: $prev"
        fi
    fi
    run ln -sfn "$dest" "$ACTIVE_RELEASE"
    # Record the absolute bin dir so later phases (Phase 8 catchup wait, verify)
    # resolve it WITHOUT $HOME — which is empty under the systemd resume service.
    state_set solana_bin "$ACTIVE_RELEASE/bin"
    ok "active_release -> releases/${tag}"
}

toolchain_setcap() {
    local bin="${1:-$(readlink -f "$ACTIVE_RELEASE/bin/agave-validator" 2>/dev/null)}"
    [[ -n "$bin" ]] || { warn "agave-validator not found for setcap"; return 0; }
    step "setcap (${TOOLCHAIN_CAPS})"
    run setcap "${TOOLCHAIN_CAPS}=p" "$bin"
    run getcap "$bin"
}

toolchain_verify() {
    if is_dry_run; then return 0; fi
    local av="$ACTIVE_RELEASE/bin/agave-validator" sol="$ACTIVE_RELEASE/bin/solana"
    if [[ -x "$av" ]];  then run "$av" --version;  else warn "agave-validator not executable at $av"; fi
    if [[ -x "$sol" ]]; then run "$sol" --version; else warn "solana not executable at $sol"; fi
}

# --- orchestrator ------------------------------------------------------------
toolchain_build() {
    require_root
    toolchain_resolve_config
    toolchain_deps
    toolchain_rust
    toolchain_anza_cli
    toolchain_fetch_source
    toolchain_apply_overlay
    toolchain_inject_lto_profile
    toolchain_patch_cargo_script
    toolchain_compile
    toolchain_install_release
    toolchain_write_threshold
    toolchain_setcap
    toolchain_verify
}
