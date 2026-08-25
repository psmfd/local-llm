#!/usr/bin/env bash
#
# setup-omlx-m5.sh — provision oMLX (jundot/omlx) as a local, OpenAI/Anthropic-
# compatible MLX inference server on an Apple Silicon M5 Max (128 GB), tuned for a
# parallel-agent coding workload.
#
# The script is idempotent: re-running detects and skips what already exists.
# Model download is OPT-IN (off by default). The API key is generated locally,
# stored 0600, and never printed or embedded in a tracked file.
#
# Usage:
#   ./setup-omlx-m5.sh [options]
#
# Options:
#   --download-model   Download the coding-workhorse model (~66 GB) via
#                      `hf download`. Off by default. Retired ADR-006 tiers are
#                      never downloaded. Existing model dirs are skipped (never
#                      re-downloaded or deleted), so this is safe to re-run when
#                      upgrading.
#   --configure-pi     Register the oMLX provider with the Pi coding agent.
#                      Auto-writes ~/.pi/agent/models.json ONLY when its
#                      providers object is empty (backup taken first);
#                      otherwise renders ~/.omlx/pi-provider-snippet.json and
#                      prints manual merge steps. No secret is written.
#   --validate         Run endpoint checks against a running server (models,
#                      chat completion, tool-calling, Anthropic endpoint, a
#                      2-way concurrency probe, and the effective cache-mode
#                      check) and exit. When combined with setup flags,
#                      validation runs by itself.
#   --verbose          Print verbose detail lines.
#   -h, --help         Show this help and exit.
#
# Exit codes:
#   0  All steps succeeded (warnings are informational only).
#   1  One or more errors occurred.
#   2  Environment or precondition failure (wrong OS/arch, insufficient
#      RAM/disk, Homebrew missing, etc.).
#
# The server is on-demand: setup does NOT start it and it does NOT start at login
# (the LaunchAgent is RunAtLoad=false). Start/stop it intentionally with the
# installed `omlxctl` tool: `omlxctl start | stop | restart | status | logs`
# (ADR-005).
#
# NOTE: oMLX's exact CLI surface and the model repo IDs were verified against
# live sources at authoring time but may drift. The script and the start wrapper
# fail loudly rather than silently mis-configuring. Confirm `omlx --help` and the
# HuggingFace repo IDs if a step errors unexpectedly.

set -euo pipefail

# --- Output helpers (script-output conventions) -----------------------------
VERBOSE=false
ok()     { echo "OK    [$1] $2"; }
skip()   { echo "SKIP  [$1] $2"; }
warn()   { echo "WARN  [$1] $2" >&2; }
info()   { echo "INFO  $*"; }
err()    { echo "ERROR [$1] $2" >&2; }
detail() { if $VERBOSE; then echo "      $*"; fi; }

error_count=0
warn_count=0
record_err()  { err "$1" "$2"; ((error_count++)) || true; }
record_warn() { warn "$1" "$2"; ((warn_count++)) || true; }

# --- Configuration ----------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TEMPLATE_DIR="$SCRIPT_DIR/templates"

OMLX_HOME="$HOME/.omlx"
# OMLX_MODEL_DIR is also the env var oMLX itself reads, so honoring it here keeps
# the script and the server pointing at the same place.
MODELS_DIR="${OMLX_MODEL_DIR:-$HOME/models}"
CACHE_DIR="${OMLX_CACHE_DIR:-$OMLX_HOME/cache}"
LOG_DIR="$OMLX_HOME/logs"
BIN_DIR="$OMLX_HOME/bin"
API_KEY_FILE="$OMLX_HOME/api-key"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"

PORT=8000
WIRED_LIMIT_MB=98304    # 96 GB; leaves ~32 GB for macOS on a 128 GB host (ADR-002)
WIRED_MIN_MB=90000      # wrapper warns below this

MIN_RAM_GB=120
MIN_DISK_GB=130         # gpt-oss-120b-4bit (~66 GB) + SSD prefix-cache tier
                        # capped at 50 GB + hf staging/logs headroom (ADR-013).
                        # Gates required FREE space only — retired tiers and the
                        # GLM fallbacks already on disk are sunk cost, not part
                        # of this floor.

# --- Model lineup (ADR-009 structure, ADR-013 model: single Mac workhorse) ---
# ADR-009's single-pinned-workhorse + cloud-frontier structure stands; ADR-013
# swapped the model and the serving shape: the Mac now serves a STRICTLY SERIAL
# workflow (one request in flight, growing transcript) rather than a parallel
# fan-out, and the workhorse is gpt-oss-120b-4bit (117B total / 5.1B active
# MoE, alternating sliding-window/full attention, ~0.070 GB/1K KV — a single
# stream reaches the model's full native 131,072 context inside the guard).
# A verified TEXT-ONLY MLX build (no vision_config → batched LLM engine, no
# engine override), Harmony tool calling verified 58/58 on oMLX 0.5.7, and
# HumanEval 95.7% vs the GLM incumbent's 83.5% (McNemar p=0.00018). Repo ID
# verified against HuggingFace config.json 2026-08-21 (#73); re-probed before
# download. See adrs/013-gptoss-serial-workhorse.md (decision + evidence),
# adrs/009-mac-single-workhorse-cloud-frontier.md (structure), and
# docs/workhorse-probes.md (probe measurements).
#
# TIER_MODELS holds exactly one entry, "repo|alias|pinned(true|false)", so every
# existing loop (download, pi-config, pin/alias, validate) works unchanged over a
# 1-element, Bash-3.2-safe indexed array (macOS default shell).
TIER_MODELS=(
    "mlx-community/gpt-oss-120b-4bit|coding-workhorse|true"
)
# The workhorse's alias drives the detailed validation probes below
# (chat/tool/concurrency).
PRIMARY_ALIAS="coding-workhorse"

# RETIRED_MODELS: models this script no longer downloads, aliases, or validates
# — the ADR-006 tiers plus the retired GLM workhorses (ADR-010's 8-bit, and
# ADR-013's 6-bit). Entries stay on disk (never deleted); the GLM-4.7-Flash-
# 6bit is the PRIMARY inactive fallback (full ADR-009/010 probe history,
# pinned-swap rollback per ADR-013), the 8-bit and Qwen3-Coder-30B the deeper
# fallbacks. apply_pins clears is_pinned/dflash on these — only when they
# already exist in oMLX's model_settings.json — so an upgraded host actually
# frees the memory. Format: "repo|alias_to_set" (2 fields — no pin field; the
# action is always force-unpin). The alias field is what the unpin PUT SETS:
# for the ADR-006 tiers it echoes their old alias unchanged (the admin PUT's
# replace-vs-merge semantics for omitted fields are unverified; a stale alias
# on an unpinned model is inert), but for the GLM-6bit it RENAMES the model
# off 'coding-workhorse' so the primary alias transfers cleanly to gpt-oss —
# which is why the unpin pass runs BEFORE the workhorse pin in apply_pins.
RETIRED_MODELS=(
    "mlx-community/GLM-4.7-Flash-6bit|workhorse-glm"
    "mlx-community/GLM-4.7-Flash-8bit|workhorse-8b"
    "lmstudio-community/Qwen3-Coder-30B-A3B-Instruct-MLX-8bit|coding-fast"
    "lmstudio-community/Qwen3-Coder-Next-MLX-4bit|coding-quality"
)

# Field accessors for a TIER_MODELS/RETIRED_MODELS entry (split on '|').
# tier_pin() is only meaningful on TIER_MODELS entries — RETIRED_MODELS entries
# have no third field; never read a pin flag from them.
tier_repo()  { printf '%s' "${1%%|*}"; }
tier_alias() { local r="${1#*|}"; printf '%s' "${r%%|*}"; }
tier_pin()   { printf '%s' "${1##*|}"; }
tier_dir()   { printf '%s' "$MODELS_DIR/$(basename "$(tier_repo "$1")")"; }

# Pi coding-agent provider registration (--configure-pi). contextWindow is
# 122880 — gpt-oss-120b's native 131,072 positions minus the 8,192 maxTokens
# decode reservation. Unlike the GLM era (ADR-011, guard-bound at 76800), the
# MODEL's position limit is now the binding constraint: the ~0.070 GB/1K KV
# slope keeps a full-native-context single stream inside the guard's dynamic
# ceiling — the #73 ladder accepted 130K-token prompts fresh-idle AND after a
# 4-hour warm-cache soak (ADR-013). Deep transcripts SHOULD still compact
# around ~60K tokens: past that the enforcer brushes soft pressure and can
# transiently pause prefill (benign, self-recovering — ADR-013 consequences).
PI_AGENT_DIR="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}"
PI_CONTEXT_WINDOW=122880
# maxTokens 8192: pi's output shrink ladder caps completions at 8,000
# (pi_config ADR-0108); stands under ADR-013 — it also sets the decode
# reservation subtracted from the native window for contextWindow above.
PI_MAX_TOKENS=8192

DAEMON_LABEL="com.local.iogpu-wired-limit"
DAEMON_PLIST="/Library/LaunchDaemons/${DAEMON_LABEL}.plist"
AGENT_LABEL="com.local.omlx"
AGENT_PLIST="$HOME/Library/LaunchAgents/${AGENT_LABEL}.plist"
WRAPPER_PATH="$BIN_DIR/omlx-start-wrapper.sh"
CONTROL_PATH="$BIN_DIR/omlxctl"   # on-demand start/stop control (ADR-005)

DO_DOWNLOAD=false
DO_VALIDATE=false
DO_CONFIGURE_PI=false
OMLX_PRESENT=false   # set by install_omlx; gates whether the LaunchAgent is started

# --- Argument parsing -------------------------------------------------------
# Print the contiguous comment block after the shebang, stripping the leading
# "# " — stops at the first non-comment line (so `set -euo pipefail` etc. are
# never leaked into --help).
usage() { awk 'NR==1{next} /^#/{sub(/^# ?/,"");print;next} {exit}' "${BASH_SOURCE[0]}"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --download-model) DO_DOWNLOAD=true ;;
        --configure-pi)   DO_CONFIGURE_PI=true ;;
        --validate)       DO_VALIDATE=true ;;
        --verbose)        VERBOSE=true ;;
        -h|--help)        usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
    esac
    shift
done

# --- Preconditions (exit 2 on hard failure) ---------------------------------
preflight() {
    info "Verifying environment"

    if [ "$(uname -s)" != "Darwin" ]; then
        err "preflight" "not macOS (uname -s = $(uname -s))"; exit 2
    fi
    ok "preflight" "macOS detected"

    # oMLX's documented support floor appears to be macOS 15 (Sequoia); this is a
    # third-party signal, not first-party, so warn rather than hard-fail. Note the
    # major version jumped to 26 (Tahoe) in 2025, so anything >= 15 is current.
    local osver osmajor
    osver="$(sw_vers -productVersion 2>/dev/null || echo 0)"
    osmajor="${osver%%.*}"
    if [ "${osmajor:-0}" -lt 15 ]; then
        record_warn "preflight" "macOS ${osver} is below 15 (Sequoia) — oMLX may require 15.0+; proceeding"
    else
        ok "preflight" "macOS ${osver}"
    fi

    if [ "$(uname -m)" != "arm64" ]; then
        err "preflight" "not Apple Silicon (uname -m = $(uname -m))"; exit 2
    fi
    ok "preflight" "arm64 (Apple Silicon)"

    local chip; chip="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo unknown)"
    if echo "$chip" | grep -q "Apple M5"; then
        ok "preflight" "chip: $chip"
    else
        record_warn "preflight" "chip is '$chip', not M5-class — tuning targets M5 Max"
    fi

    local mem_bytes mem_gb
    mem_bytes="$(sysctl -n hw.memsize 2>/dev/null || echo 0)"
    mem_gb=$(( mem_bytes / 1024 / 1024 / 1024 ))
    if [ "$mem_gb" -lt "$MIN_RAM_GB" ]; then
        err "preflight" "RAM ${mem_gb} GB < required ${MIN_RAM_GB} GB"; exit 2
    fi
    ok "preflight" "RAM ${mem_gb} GB"

    local avail_kb avail_gb
    avail_kb="$(df -k "$HOME" | awk 'NR==2{print $4}')"
    avail_gb=$(( avail_kb / 1024 / 1024 ))
    if [ "$avail_gb" -lt "$MIN_DISK_GB" ]; then
        err "preflight" "free disk ${avail_gb} GB < required ${MIN_DISK_GB} GB on $HOME"; exit 2
    fi
    ok "preflight" "free disk ${avail_gb} GB"

    if ! command -v brew >/dev/null 2>&1; then
        err "preflight" "Homebrew not found — install from https://brew.sh"; exit 2
    fi
    ok "preflight" "Homebrew present ($(brew --prefix))"
}

brew_prefix() { brew --prefix 2>/dev/null || echo /opt/homebrew; }

# --- Step: install oMLX (no MCP extra) --------------------------------------
install_omlx() {
    if brew list omlx >/dev/null 2>&1; then
        skip "install" "omlx already installed ($(omlx --version 2>/dev/null || echo 'version unknown'))"
        OMLX_PRESENT=true
        return
    fi
    info "Installing oMLX via Homebrew (no MCP extra)"
    if ! brew tap | grep -qi '^jundot/omlx$'; then
        brew tap jundot/omlx https://github.com/jundot/omlx
    fi
    # Homebrew ≥4.6 refuses to load formulae from untrusted third-party taps.
    # Installing from this tap IS the settled runtime decision (ADR-001→003), so
    # trusting it is implied; on older brews without `brew trust` this no-ops.
    if brew trust jundot/omlx >/dev/null 2>&1; then
        ok "install" "trusted tap jundot/omlx"
    fi
    if brew install omlx; then
        ok "install" "omlx installed"
        OMLX_PRESENT=true
    else
        record_err "install" "brew install omlx failed — the service will be configured but NOT started"
    fi
}

# --- Step: create directories -----------------------------------------------
ensure_dirs() {
    local d
    for d in "$OMLX_HOME" "$MODELS_DIR" "$CACHE_DIR" "$LOG_DIR" "$BIN_DIR" "$LAUNCH_AGENTS_DIR"; do
        if [ -d "$d" ]; then
            skip "dirs" "$d exists"
        elif mkdir -p "$d"; then
            ok "dirs" "created $d"
        else
            record_err "dirs" "failed to create $d"
        fi
    done
    # ~/.omlx holds the API key and the start wrapper — restrict to the owner so
    # other local users cannot enumerate its contents (the key file is 0600, but
    # the directory would otherwise be 0755 under a default umask).
    chmod 700 "$OMLX_HOME" "$BIN_DIR" 2>/dev/null || true
    # oMLX copies its CLI arguments — INCLUDING the api key (.auth.api_key) —
    # into settings.json at startup, written 0644. The 0700 dir already blocks
    # other users; tighten the file anyway whenever it exists.
    if [ -f "$OMLX_HOME/settings.json" ]; then
        chmod 600 "$OMLX_HOME/settings.json" 2>/dev/null || true
    fi
}

# --- Step: generate API key (0600) ------------------------------------------
ensure_api_key() {
    if [ -f "$API_KEY_FILE" ]; then
        skip "api-key" "$API_KEY_FILE exists (left untouched)"
        chmod 600 "$API_KEY_FILE"
        return
    fi
    # Write to a temp file in the same directory, then atomically rename. Writing
    # directly with `>` would truncate/create the target before openssl runs, so a
    # mid-generation failure would leave an EMPTY 0600 file that the next run skips
    # (server then starts with a blank key). The mktemp+mv avoids that race.
    local tmp
    tmp="$(umask 077; mktemp "${OMLX_HOME}/.api-key.XXXXXX")" || {
        record_err "api-key" "mktemp failed in $OMLX_HOME"; return; }
    if (umask 077; openssl rand -hex 32 > "$tmp"); then
        chmod 600 "$tmp"
        mv "$tmp" "$API_KEY_FILE"
        ok "api-key" "generated $API_KEY_FILE (0600)"
        detail "key value not printed by design"
    else
        rm -f "$tmp"
        record_err "api-key" "openssl rand failed — no key written"
    fi
}

# --- Template rendering ------------------------------------------------------
# render_template SRC DEST KEY1 VAL1 [KEY2 VAL2 ...]
# Returns 0 when the dest was created/changed, 1 when already current, 2 on error.
render_template() {
    local src="$1" dest="$2"; shift 2
    [ -f "$src" ] || { record_err "template" "missing template: $src"; return 2; }
    if [ $(( $# % 2 )) -ne 0 ]; then
        record_err "template" "render_template: odd key/value argument count for $src"; return 2
    fi
    local tmp; tmp="$(mktemp)" || { record_err "template" "mktemp failed"; return 2; }
    if ! cp "$src" "$tmp"; then
        rm -f "$tmp"
        record_err "template" "failed to stage template: $src"
        return 2
    fi
    while [ $# -gt 0 ]; do
        local key="$1" val="$2"; shift 2
        # '|' delimiter — values are filesystem paths containing '/'. Escape the
        # sed replacement metacharacters (\ and &) and the delimiter in the value.
        val="${val//\\/\\\\}"; val="${val//&/\\&}"; val="${val//|/\\|}"
        if ! sed -i '' -e "s|${key}|${val}|g" "$tmp"; then
            rm -f "$tmp"
            record_err "template" "failed to render placeholder ${key} in $src"
            return 2
        fi
    done
    if [ -f "$dest" ] && cmp -s "$tmp" "$dest"; then
        rm -f "$tmp"
        return 1   # unchanged
    fi
    if ! cp "$tmp" "$dest"; then
        rm -f "$tmp"
        record_err "template" "failed to write rendered template: $dest"
        return 2
    fi
    rm -f "$tmp"
    return 0       # changed/created
}

# --- Step: Metal wired limit (LaunchDaemon, needs sudo) ---------------------
install_wired_limit() {
    info "Configuring Metal wired-memory limit (${WIRED_LIMIT_MB} MB) — sudo required"

    # Apply immediately for the current session (idempotent).
    local cur; cur="$(sysctl -n iogpu.wired_limit_mb 2>/dev/null || echo 0)"
    if [ "${cur:-0}" -ge "$WIRED_LIMIT_MB" ]; then
        skip "wired-now" "iogpu.wired_limit_mb already ${cur}"
    else
        if sudo sysctl iogpu.wired_limit_mb=$WIRED_LIMIT_MB >/dev/null; then
            ok "wired-now" "set iogpu.wired_limit_mb=${WIRED_LIMIT_MB} for this session"
        else
            record_err "wired-now" "failed to set sysctl iogpu.wired_limit_mb"
        fi
    fi

    # Persist across reboot via a root LaunchDaemon. Render into a shell variable
    # and pipe straight to `sudo tee` — no user-writable file is ever staged in a
    # privileged path, which closes the mktemp -> `sudo cp` TOCTOU window (a
    # same-user process could otherwise swap the temp file before the copy). The
    # 0644 daemon plist is world-readable, so the compare needs no sudo.
    local rendered
    rendered="$(sed -e "s|__WIRED_LIMIT_MB__|${WIRED_LIMIT_MB}|g" \
        "$TEMPLATE_DIR/com.local.iogpu-wired-limit.plist")"

    if [ -f "$DAEMON_PLIST" ] && [ "$rendered" = "$(cat "$DAEMON_PLIST")" ]; then
        skip "wired-daemon" "$DAEMON_PLIST already current"
    else
        printf '%s\n' "$rendered" | sudo tee "$DAEMON_PLIST" >/dev/null
        sudo chown root:wheel "$DAEMON_PLIST"
        sudo chmod 644 "$DAEMON_PLIST"
        # Reload if already bootstrapped so the next boot uses the new value.
        if sudo launchctl print "system/${DAEMON_LABEL}" >/dev/null 2>&1; then
            sudo launchctl bootout "system/${DAEMON_LABEL}" 2>/dev/null || true
        fi
        ok "wired-daemon" "installed $DAEMON_PLIST (root:wheel 0644)"
    fi

    # Loaded-check without sudo first: `launchctl print system/<label>` is
    # readable unprivileged, and a sudo-wrapped check fails under NON-INTERACTIVE
    # sudo even when the job IS loaded — which then mis-fires a bootstrap attempt
    # and records a spurious error on an already-converged host.
    if launchctl print "system/${DAEMON_LABEL}" >/dev/null 2>&1 \
        || sudo launchctl print "system/${DAEMON_LABEL}" >/dev/null 2>&1; then
        skip "wired-daemon" "LaunchDaemon already loaded"
    else
        if sudo launchctl bootstrap system "$DAEMON_PLIST"; then
            ok "wired-daemon" "LaunchDaemon bootstrapped (persists across reboot)"
        else
            record_err "wired-daemon" "launchctl bootstrap system failed"
        fi
    fi
}

# --- Step: start wrapper + LaunchAgent --------------------------------------
check_omlx_cli() {
    local prefix="$1"
    local omlx_bin="$prefix/bin/omlx"
    local help_text
    local flag
    local missing=false

    if [ ! -x "$omlx_bin" ]; then
        record_err "omlx-cli" "expected executable not found: $omlx_bin"
        return 1
    fi
    if ! help_text="$("$omlx_bin" serve --help 2>&1)"; then
        record_err "omlx-cli" "failed to inspect '$omlx_bin serve --help' — verify the oMLX CLI before starting the LaunchAgent"
        return 1
    fi
    for flag in --host --model-dir --port --memory-guard-gb --paged-ssd-cache-dir --paged-ssd-cache-max-size --hot-cache-max-size --max-concurrent-requests --api-key; do
        if ! printf '%s\n' "$help_text" | grep -q -- "$flag"; then
            record_err "omlx-cli" "'omlx serve --help' does not advertise expected flag: $flag"
            missing=true
        fi
    done
    if $missing; then
        return 1
    fi
    ok "omlx-cli" "serve command exposes expected flags"
}

install_service() {
    info "Installing start wrapper and LaunchAgent"
    local prefix; prefix="$(brew_prefix)"

    # svc_changed tracks EITHER artifact: the LaunchAgent exec's the wrapper, so a
    # wrapper-only change still requires a reload for the running server to pick it
    # up (the old wrapper is held in the running process until restart).
    local svc_changed=false

    if render_template "$TEMPLATE_DIR/omlx-start-wrapper.sh" "$WRAPPER_PATH" \
        "__BREW_PREFIX__" "$prefix" \
        "__MODEL_DIR__"   "$MODELS_DIR" \
        "__CACHE_DIR__"   "$CACHE_DIR" \
        "__API_KEY_FILE__" "$API_KEY_FILE" \
        "__WIRED_MIN_MB__" "$WIRED_MIN_MB"; then
        chmod 755 "$WRAPPER_PATH"
        ok "wrapper" "installed $WRAPPER_PATH"
        svc_changed=true
    else
        case "$?" in
            1)
                chmod 755 "$WRAPPER_PATH"
                skip "wrapper" "$WRAPPER_PATH already current"
                ;;
            2) return 0 ;;
            *) record_err "wrapper" "unexpected render_template status"; return 0 ;;
        esac
    fi

    if render_template "$TEMPLATE_DIR/com.local.omlx.plist" "$AGENT_PLIST" \
        "__WRAPPER_PATH__" "$WRAPPER_PATH" \
        "__OMLX_HOME__"    "$HOME" \
        "__LOG_DIR__"      "$LOG_DIR" \
        "__BREW_PREFIX__"  "$prefix"; then
        chmod 644 "$AGENT_PLIST"
        ok "agent" "installed $AGENT_PLIST"
        svc_changed=true
    else
        case "$?" in
            1)
                chmod 644 "$AGENT_PLIST"
                skip "agent" "$AGENT_PLIST already current"
                ;;
            2) return 0 ;;
            *) record_err "agent" "unexpected render_template status"; return 0 ;;
        esac
    fi

    # Register the LaunchAgent only once omlx exists. The agent is RunAtLoad=false,
    # so bootstrapping it merely makes the job kickstart-able (it does NOT start the
    # server, here or at login). The config is installed regardless; registration
    # waits until omlx exists so `omlxctl start` has something to launch.
    if ! $OMLX_PRESENT; then
        record_warn "agent" "omlx not installed — LaunchAgent configured but not registered; re-run after installing omlx"
        return
    fi
    if ! check_omlx_cli "$prefix"; then
        return
    fi

    if launchctl print "gui/$(id -u)/${AGENT_LABEL}" >/dev/null 2>&1; then
        if $svc_changed; then
            launchctl bootout "gui/$(id -u)/${AGENT_LABEL}" 2>/dev/null || true
            if launchctl bootstrap "gui/$(id -u)" "$AGENT_PLIST"; then
                ok "agent" "re-registered LaunchAgent (wrapper or plist changed; not started)"
            else
                record_err "agent" "launchctl bootstrap (reload) failed"
            fi
        else
            skip "agent" "LaunchAgent already registered"
        fi
    else
        if launchctl bootstrap "gui/$(id -u)" "$AGENT_PLIST"; then
            ok "agent" "LaunchAgent registered (on-demand — NOT started at login; start with: omlxctl start)"
        else
            record_err "agent" "launchctl bootstrap gui failed"
        fi
    fi
}

# --- Step: install the omlxctl control tool ---------------------------------
# omlxctl is a static script (no placeholder substitution); render_template with
# no key/value pairs just stages + copies it with the standard idempotency check.
# Per the "Both" install choice (ADR-005): symlink it into the Homebrew bin when
# that directory is writable, and always print the manual PATH fallback.
install_control() {
    info "Installing the omlxctl on-demand control tool"

    if render_template "$TEMPLATE_DIR/omlxctl" "$CONTROL_PATH"; then
        chmod 755 "$CONTROL_PATH"
        ok "control" "installed $CONTROL_PATH"
    else
        case "$?" in
            1) chmod 755 "$CONTROL_PATH"; skip "control" "$CONTROL_PATH already current" ;;
            2) return 0 ;;   # render_template already recorded the error
            *) record_err "control" "unexpected render_template status"; return 0 ;;
        esac
    fi

    # Symlink into the Homebrew bin so `omlxctl` is on PATH (Both: link + fallback).
    local link; link="$(brew_prefix)/bin/omlxctl"
    local bindir; bindir="$(dirname "$link")"
    if [ -L "$link" ] && [ "$(readlink "$link")" = "$CONTROL_PATH" ]; then
        skip "control-link" "$link already -> $CONTROL_PATH"
    elif [ -e "$link" ] && [ ! -L "$link" ]; then
        record_warn "control-link" "$link exists and is not our symlink — not overwriting; invoke $CONTROL_PATH directly"
    elif [ -w "$bindir" ]; then
        if ln -sfn "$CONTROL_PATH" "$link"; then
            ok "control-link" "symlinked $link -> $CONTROL_PATH (run: omlxctl start)"
        else
            record_warn "control-link" "failed to symlink $link — run manually: ln -sfn $CONTROL_PATH $link"
        fi
    else
        record_warn "control-link" "$bindir not writable — run: ln -sfn $CONTROL_PATH $link  (or add ~/.omlx/bin to PATH)"
    fi
}

# --- Step: download a model via hf ------------------------------------------
verify_hf_repo() {
    local repo="$1" label="$2"
    local url="https://huggingface.co/api/models/${repo}"

    if ! command -v curl >/dev/null 2>&1; then
        record_err "$label" "curl not found — cannot verify Hugging Face repo before download"
        return 1
    fi
    info "Verifying Hugging Face repo exists: $repo"
    if curl -fsS --max-time 20 "$url" >/dev/null; then
        ok "$label" "verified Hugging Face repo: $repo"
        return 0
    fi
    record_err "$label" "could not verify Hugging Face repo $repo — confirm the current MLX repo ID before downloading"
    return 1
}

download_model() {
    local repo="$1" dest="$2" label="$3"

    if [ -d "$dest" ] && [ -n "$(ls -A "$dest" 2>/dev/null)" ]; then
        skip "$label" "$dest already populated"
        return
    fi
    # Prefer the current `hf` CLI; fall back to the legacy `huggingface-cli`
    # (same `download` subcommand schema, different auth subcommands).
    local hf_cmd login_cmd
    if command -v hf >/dev/null 2>&1; then
        hf_cmd="hf"; login_cmd="hf auth login"
    elif command -v huggingface-cli >/dev/null 2>&1; then
        hf_cmd="huggingface-cli"; login_cmd="huggingface-cli login"
        detail "using legacy huggingface-cli ('hf' not found)"
    else
        info "No HuggingFace CLI found — installing huggingface-cli via Homebrew"
        if ! brew install huggingface-cli; then
            record_err "$label" "brew install huggingface-cli failed — install it manually (pip install huggingface_hub) and re-run"
            return
        fi
        if command -v hf >/dev/null 2>&1; then
            hf_cmd="hf"; login_cmd="hf auth login"
        elif command -v huggingface-cli >/dev/null 2>&1; then
            hf_cmd="huggingface-cli"; login_cmd="huggingface-cli login"
        else
            record_err "$label" "huggingface-cli installed but neither 'hf' nor 'huggingface-cli' is on PATH — open a new shell and re-run"
            return
        fi
        ok "$label" "installed HuggingFace CLI ($hf_cmd)"
    fi
    if ! verify_hf_repo "$repo" "$label"; then
        return
    fi
    # These repos are ungated, but honor the configured 'handle login' behavior:
    # if auth probing fails AND the download then fails, point at the login command.
    local whoami_ok=true
    if [ "$hf_cmd" = "hf" ]; then
        hf auth whoami >/dev/null 2>&1 || whoami_ok=false
    else
        huggingface-cli whoami >/dev/null 2>&1 || whoami_ok=false
    fi
    if ! $whoami_ok; then
        record_warn "$label" "not logged in to Hugging Face — ungated repo should still download; if it fails, run: $login_cmd"
    fi
    info "Downloading $repo -> $dest (this is large; may take a while)"
    if "$hf_cmd" download "$repo" --local-dir "$dest"; then
        ok "$label" "downloaded $repo"
    else
        record_err "$label" "$hf_cmd download failed for $repo — if the repo is gated, run: $login_cmd"
    fi
}

maybe_download_models() {
    if ! $DO_DOWNLOAD; then
        # Download is opt-in, but a run that leaves ~/models empty produces a
        # server that serves zero models with no WARN/ERROR — surface that end
        # state here instead of leaving it for a server.log dive (issue #4).
        local present=0 entry
        for entry in "${TIER_MODELS[@]}"; do
            [ -d "$(tier_dir "$entry")" ] && { ((present++)) || true; }
        done
        if [ "$present" -eq 0 ]; then
            record_warn "model" "download is opt-in and the workhorse model is not on disk — the server will serve ZERO models until you run: ./setup-omlx-m5.sh --download-model (then pin/alias in /admin)"
        else
            skip "model" "download is opt-in — workhorse model already on disk"
        fi
        return
    fi
    # Only the ADR-009 workhorse is fetched. Retired ADR-006 tiers are never
    # downloaded (Qwen3-Coder-30B stays on disk as the inactive fallback if a
    # prior install put it there). download_model() skips a populated dir, so an
    # upgrade re-run fetches nothing it already has.
    local entry
    for entry in "${TIER_MODELS[@]}"; do
        download_model "$(tier_repo "$entry")" "$(tier_dir "$entry")" "model-$(tier_alias "$entry")"
    done
}

# --- Step: Pi coding-agent provider registration (--configure-pi) -----------
# ~/.pi/agent/models.json is hand-edited JSONC inside a version-controlled
# repo; a programmatic merge (jq/python3) would strip its comments. The only
# auto-write case is the provably safe one: file absent, or a comment-stripped
# parse shows an empty providers object (backup taken first; git covers the
# rest). Anything else gets the rendered snippet plus manual merge steps.
print_pi_settings_instructions() {
    local settings_file="$1"
    # settings.json is hand-curated and git-tracked; never edited automatically.
    info "To surface the workhorse in Pi's picker, add to the enabledModels array in $settings_file:"
    local entry
    for entry in "${TIER_MODELS[@]}"; do
        echo "      \"omlx/$(tier_alias "$entry")\""
    done
    echo "      Select with: pi --model omlx/$(tier_alias "${TIER_MODELS[0]}")  (or /model in a session — models.json reloads on /model)"
}

configure_pi_provider() {
    info "Configuring the Pi coding-agent oMLX provider"

    if ! command -v pi >/dev/null 2>&1; then
        record_warn "pi-config" "pi binary not found on PATH — install Pi, then re-run with --configure-pi"
        return
    fi
    if [ ! -d "$PI_AGENT_DIR" ]; then
        record_warn "pi-config" "Pi agent dir not found: $PI_AGENT_DIR — run Pi once to create it, then re-run with --configure-pi"
        return
    fi

    local models_file="$PI_AGENT_DIR/models.json"
    local settings_file="$PI_AGENT_DIR/settings.json"
    local snippet_dest="$OMLX_HOME/pi-provider-snippet.json"
    # Register the workhorse by its oMLX alias (ADR-009).
    local model_id
    model_id="$(tier_alias "${TIER_MODELS[0]}")"

    if render_template "$TEMPLATE_DIR/pi-models-omlx.json" "$snippet_dest" \
        "__PORT__"              "$PORT" \
        "__API_KEY_FILE__"      "$API_KEY_FILE" \
        "__MODEL_ID__"          "$model_id" \
        "__PI_CONTEXT_WINDOW__" "$PI_CONTEXT_WINDOW" \
        "__PI_MAX_TOKENS__"     "$PI_MAX_TOKENS"; then
        ok "pi-config" "rendered provider snippet: $snippet_dest"
    else
        case "$?" in
            1) skip "pi-config" "provider snippet already current: $snippet_dest" ;;
            *) return 0 ;;   # render_template already recorded the error
        esac
    fi

    # Idempotency: never rewrite a models.json that already names this provider.
    if [ -f "$models_file" ] && grep -q '"omlx"' "$models_file"; then
        skip "pi-config" "\"omlx\" provider already present in $models_file (left untouched)"
        print_pi_settings_instructions "$settings_file"
        return
    fi

    local providers_empty=false
    if [ ! -f "$models_file" ]; then
        providers_empty=true
    elif python3 - "$models_file" <<'PYEOF' 2>/dev/null
import json, re, sys
text = open(sys.argv[1]).read()
# Strip full-line JSONC comments only — a naive //-strip would eat "http://..."
# string values. A trailing-comment file fails the parse and safely falls
# through to the manual-merge path.
stripped = re.sub(r"^\s*//[^\n]*$", "", text, flags=re.M)
sys.exit(0 if json.loads(stripped).get("providers") == {} else 1)
PYEOF
    then
        providers_empty=true
    fi

    if $providers_empty; then
        if [ -f "$models_file" ]; then
            local bak; bak="${models_file}.bak.$(date +%Y%m%d%H%M%S)"
            if ! cp "$models_file" "$bak"; then
                record_err "pi-config" "backup of $models_file failed — not writing"
                return
            fi
            detail "backed up existing models.json to $bak"
        fi
        if cp "$snippet_dest" "$models_file"; then
            ok "pi-config" "wrote oMLX provider to $models_file (git-tracked — review with 'git diff' in the pi config repo)"
        else
            record_err "pi-config" "failed to write $models_file"
            return
        fi
    else
        record_warn "pi-config" "$models_file already has provider entries — manual merge required (a scripted merge would strip its JSONC comments)"
        info "Insert the \"omlx\" block from $snippet_dest into the providers object of $models_file"
    fi

    print_pi_settings_instructions "$settings_file"
}

# --- Pin/alias fallback instructions (when the admin API can't be reached) --
print_pin_instructions() {
    # Printed when apply_pins cannot reach the admin API, so the operator can
    # set the workhorse alias/pin — and clear any retired ADR-006 pins —
    # manually in the admin panel.
    info "Apply the workhorse alias + pin manually in the admin panel:"
    echo "      1. Start the server (omlxctl start), then open http://localhost:${PORT}/admin"
    echo "      2. Under Models, set the alias and pin state:"
    local entry
    for entry in "${TIER_MODELS[@]}"; do
        echo "         - $(basename "$(tier_repo "$entry")")  alias '$(tier_alias "$entry")'  PIN (sole resident model)"
    done
    echo "      3. If upgrading from a prior install, also UNPIN the retired models BEFORE"
    echo "         pinning the workhorse (they stay on disk — the 8-bit is the primary inactive"
    echo "         fallback, Qwen3-Coder-30B the secondary; ADR-010):"
    local r
    for r in "${RETIRED_MODELS[@]}"; do
        echo "         - $(basename "$(tier_repo "$r")")  UNPIN (clear is_pinned; DFlash off; set alias '$(tier_alias "$r")')"
    done
    echo "      Aliases/pins persist in ${OMLX_HOME}/model_settings.json and appear in GET /v1/models."
    echo "      No engine override is needed — the workhorse is a text-only coder build (ADR-009/010)."
}

# retired_model_state REPO — reads the LOCAL oMLX-owned model_settings.json
# (never the server; schema — basename-keyed "models" map with model_alias /
# is_pinned / dflash_ssd_cache fields — verified against oMLX 0.4.4) and prints:
#   absent  oMLX has never registered this model — no PUT should be sent
#           (retired tiers are never actively aliased/registered by us)
#   dirty   present and still is_pinned or dflash_ssd_cache — OR still holding
#           the primary alias (an unpinned GLM squatting on 'coding-workhorse'
#           would collide with the workhorse's alias PUT; ADR-010/013) — OR
#           still holding is_default (#77: a retired tier must not be the
#           model the server resolves for a default-model consumer) — needs a PUT
#   clean   present, unpinned/dflash-off, not on the primary alias, not the
#           default — nothing to do
# Shared by pins_converged (gate) and apply_pins (action) — one source of truth.
retired_model_state() {
    local repo="$1"
    [ -f "$OMLX_HOME/model_settings.json" ] || { printf 'absent'; return; }
    python3 - "$OMLX_HOME/model_settings.json" "$(basename "$repo")" "$PRIMARY_ALIAS" <<'PYEOF' 2>/dev/null || printf 'absent'
import json, sys
try:
    models = json.load(open(sys.argv[1])).get("models", {})
except Exception:
    print("absent"); sys.exit(0)
m = models.get(sys.argv[2])
if not m:
    print("absent")
elif (bool(m.get("is_pinned")) or bool(m.get("dflash_ssd_cache"))
      or bool(m.get("is_default"))
      or m.get("model_alias") == sys.argv[3]):
    print("dirty")
else:
    print("clean")
PYEOF
}

# Idempotency gate: returns 0 only when the host is fully converged on ADR-009 —
# the workhorse has its alias + pin in model_settings.json, no retired
# ADR-006 tier is still pinned (absent-or-clean), AND no model outside
# TIER_MODELS holds a pin (the sole-resident invariant, #43: a stray pin from
# an admin-panel experiment or an incident rollback would double-dip weights
# into the memory guard). An upgraded host with a retired tier still pinned is
# NOT converged, so the unpin pass runs; a converged host skips the whole
# start/pin/stop cycle (no server churn). We only READ the oMLX-owned file here.
pins_converged() {
    [ -f "$OMLX_HOME/model_settings.json" ] || return 1
    if ! python3 - "$OMLX_HOME/model_settings.json" "${TIER_MODELS[@]}" <<'PYEOF' 2>/dev/null
import json, os, sys
try:
    models = json.load(open(sys.argv[1])).get("models", {})
except Exception:
    sys.exit(1)
pinned_tiers = set()
for t in sys.argv[2:]:
    repo, alias, pin = t.split("|")
    mid = os.path.basename(repo)
    if pin == "true":
        pinned_tiers.add(mid)
    m = models.get(mid)
    if not m or m.get("model_alias") != alias or bool(m.get("is_pinned")) != (pin == "true"):
        sys.exit(1)
    # The pinned workhorse must also OWN the default (#77): oMLX otherwise
    # derives it from registry order, which lands on a retired tier.
    if pin == "true" and not bool(m.get("is_default")):
        sys.exit(1)
# Sole-resident invariant: any pin — or default (#77) — outside the tier
# lineup is a stray (#43).
for mid, m in models.items():
    if mid not in pinned_tiers and (bool(m.get("is_pinned")) or bool(m.get("is_default"))):
        sys.exit(1)
sys.exit(0)
PYEOF
    then
        return 1
    fi
    local r
    for r in "${RETIRED_MODELS[@]}"; do
        [ "$(retired_model_state "$(tier_repo "$r")")" = "dirty" ] && return 1
    done
    return 0
}

# stray_pins — prints one "model_id|alias" line per model pinned in
# model_settings.json that is not a TIER_MODELS pin. Shared source of truth for
# pins_converged (gate, via the equivalent inline check) and apply_pins
# (action). Retired tiers never appear here when already handled — the unpin
# pass runs first — but if one is still pinned it IS listed, harmlessly: the
# stray unpin PUT is idempotent with the retired unpin PUT.
stray_pins() {
    [ -f "$OMLX_HOME/model_settings.json" ] || return 0
    python3 - "$OMLX_HOME/model_settings.json" "${TIER_MODELS[@]}" <<'PYEOF' 2>/dev/null || true
import json, os, sys
try:
    models = json.load(open(sys.argv[1])).get("models", {})
except Exception:
    sys.exit(0)
pinned_tiers = set()
for t in sys.argv[2:]:
    repo, alias, pin = t.split("|")
    if pin == "true":
        pinned_tiers.add(os.path.basename(repo))
for mid, m in models.items():
    if bool(m.get("is_pinned")) and mid not in pinned_tiers:
        print(f"{mid}|{m.get('model_alias') or ''}")
PYEOF
}

# stray_defaults — prints one "model_id|alias" line per model holding
# is_default in model_settings.json that is not the pinned TIER_MODELS entry.
# Mirrors stray_pins (#43) for the default flag (#77). A default can sit on an
# UNPINNED model — the GLM-6bit case that motivated this — so stray_pins does
# not catch it and a separate pass is required. Retired tiers handled by the
# unpin pass may also appear here; the extra PUT is idempotent.
stray_defaults() {
    [ -f "$OMLX_HOME/model_settings.json" ] || return 0
    python3 - "$OMLX_HOME/model_settings.json" "${TIER_MODELS[@]}" <<'PYEOF' 2>/dev/null || true
import json, os, sys
try:
    models = json.load(open(sys.argv[1])).get("models", {})
except Exception:
    sys.exit(0)
pinned_tiers = set()
for t in sys.argv[2:]:
    repo, alias, pin = t.split("|")
    if pin == "true":
        pinned_tiers.add(os.path.basename(repo))
for mid, m in models.items():
    if bool(m.get("is_default")) and mid not in pinned_tiers:
        print(f"{mid}|{m.get('model_alias') or ''}")
PYEOF
}

# --- Pin/alias via the oMLX admin API (ADR-009) -----------------------------
# Sets the workhorse alias + pin — and clears any retired ADR-006 tier pins — by
# briefly starting the server, PUTting the per-model settings, then stopping it,
# so ADR-005's end-state invariant (server stopped after setup, no login
# autostart) is preserved. model_settings.json is oMLX-owned, so we go through
# the admin API rather than writing the file. The admin mount prefix is probed
# (it has drifted between /admin/api and /api). The whole step degrades to
# print_pin_instructions + a warning — never a hard failure.
apply_pins() {
    if ! $OMLX_PRESENT; then
        record_warn "pin" "omlx not installed — skipping admin pinning; re-run after installing omlx"
        print_pin_instructions; return
    fi
    if [ ! -r "$API_KEY_FILE" ]; then
        record_warn "pin" "API key not readable — skipping admin pinning"
        print_pin_instructions; return
    fi
    local workhorse_present=false entry
    for entry in "${TIER_MODELS[@]}"; do
        if [ -d "$(tier_dir "$entry")" ] && [ -n "$(ls -A "$(tier_dir "$entry")" 2>/dev/null)" ]; then workhorse_present=true; fi
    done
    # If nothing is on disk AND oMLX has no model_settings.json, there is nothing
    # to pin and nothing to unpin — skip without a server start. Do NOT gate on
    # the workhorse alone: a prior ADR-006 install may still hold retired-tier
    # pins that need clearing even before the workhorse is downloaded.
    if ! $workhorse_present && [ ! -f "$OMLX_HOME/model_settings.json" ]; then
        skip "pin" "workhorse not on disk and no model_settings.json — download it (--download-model), then re-run to apply pins"
        print_pin_instructions; return
    fi
    if pins_converged; then
        skip "pin" "workhorse alias + pin set and no retired-tier pins to clear (no server start needed)"
        return
    fi

    local key base auth
    key="$(cat "$API_KEY_FILE")"
    base="http://localhost:${PORT}"
    auth="Authorization: Bearer ${key}"

    # Only stop the server afterwards if WE started it (respect an already-running server).
    local started_by_us=false
    if ! curl -fsS --max-time 3 -H "$auth" "${base}/health" >/dev/null 2>&1; then
        info "Briefly starting the server to apply pins (will stop it afterwards)"
        if [ -x "$CONTROL_PATH" ] && "$CONTROL_PATH" start >/dev/null 2>&1; then
            started_by_us=true
        else
            # omlxctl start returns non-zero both when kickstart fails AND when
            # kickstart succeeded but readiness timed out — in the timeout case
            # the server IS running and still loading the model. Best-effort
            # stop either way (safe: the health probe above said nothing was
            # running before we tried), so setup never leaves a half-started
            # server resident (ADR-005 end-state invariant).
            [ -x "$CONTROL_PATH" ] && "$CONTROL_PATH" stop >/dev/null 2>&1 || true
            record_warn "pin" "server did not start or did not become ready in time — stopped any partial start; re-run setup to apply pins"
            print_pin_instructions; return
        fi
    fi

    local ready=false
    for _ in $(seq 1 60); do
        if curl -fsS --max-time 3 -H "$auth" "${base}/health" >/dev/null 2>&1; then ready=true; break; fi
        sleep 2
    done
    if ! $ready; then
        record_warn "pin" "server did not become ready — skipping admin pinning"
        $started_by_us && "$CONTROL_PATH" stop >/dev/null 2>&1 || true
        print_pin_instructions; return
    fi

    # oMLX persists its CLI args — including a copy of the API key — into
    # settings.json, written 0644 on the first-ever start. ensure_dirs only
    # tightens a pre-existing file, so close the gap here, right after the
    # first start this run may have triggered.
    [ -f "$OMLX_HOME/settings.json" ] && chmod 600 "$OMLX_HOME/settings.json" 2>/dev/null || true

    # Admin auth: oMLX >= 0.4.4 requires a session login (POST /admin/api/login
    # with the API key -> session cookie; the "api_key" body field name is
    # verified against oMLX 0.4.4); the bearer key alone gets a 401
    # "Admin authentication required". Older builds accepted the bearer key
    # directly, so the probe below still sends both — the cookie jar is empty
    # (harmless) when the login endpoint does not exist.
    # SECURITY NOTE: the key rides curl's argv (-H/-d) for these brief admin
    # calls — visible to other local accounts via ps for each subprocess's
    # lifetime. Same accepted gap as the wrapper's --api-key (ADR-001):
    # loopback-only server on a single-user host.
    # The session-cookie jar lives under the 0700 $OMLX_HOME (not shared /tmp),
    # so even an abnormal exit that skips the rm below leaves the residue
    # unreadable to other accounts.
    local cookie_jar
    cookie_jar="$(mktemp "${OMLX_HOME}/.admin-cookie.XXXXXX")"
    if curl -fsS --max-time 5 -c "$cookie_jar" -H 'Content-Type: application/json' \
        -d "{\"api_key\":\"${key}\"}" "${base}/admin/api/login" >/dev/null 2>&1; then
        detail "admin session established via /admin/api/login"
    fi

    # Probe the admin mount prefix (cookie + bearer — whichever the build honors).
    local admin="" p
    for p in "/admin/api" "/api"; do
        if curl -fsS --max-time 5 -b "$cookie_jar" -H "$auth" "${base}${p}/models" >/dev/null 2>&1; then admin="$p"; break; fi
    done
    if [ -z "$admin" ]; then
        record_warn "pin" "admin API not found at /admin/api or /api — apply pins manually"
        rm -f "$cookie_jar"
        $started_by_us && "$CONTROL_PATH" stop >/dev/null 2>&1 || true
        print_pin_instructions; return
    fi
    detail "admin API mounted at ${admin}"

    # Retired models FIRST: force-unpin (and, for the ADR-010-retired 8-bit,
    # rename off the primary alias) whatever a prior install left registered, so
    # the memory is actually freed AND 'coding-workhorse' is vacant before the
    # workhorse PUT below claims it (see RETIRED_MODELS comment). Only entries
    # already registered in model_settings.json are touched; ttl_seconds bounds
    # any accidental load of the now-unpinned model.
    local r rmid rstate ralias body
    for r in "${RETIRED_MODELS[@]}"; do
        rmid="$(basename "$(tier_repo "$r")")"
        ralias="$(tier_alias "$r")"
        rstate="$(retired_model_state "$(tier_repo "$r")")"
        case "$rstate" in
            absent) skip "unpin-${rmid}" "not in model_settings.json — never registered, nothing to unpin" ;;
            clean)  skip "unpin-${rmid}" "already unpinned (DFlash off, primary alias clear)" ;;
            dirty)
                body="{\"model_alias\":\"${ralias}\",\"is_pinned\":false,\"is_default\":false,\"ttl_seconds\":900,\"dflash_ssd_cache\":false}"
                if curl -fsS --max-time 20 -X PUT -b "$cookie_jar" -H "$auth" -H 'Content-Type: application/json' \
                    -d "$body" "${base}${admin}/models/${rmid}/settings" >/dev/null 2>&1; then
                    ok "unpin-${rmid}" "retired model unpinned as '${ralias}' (stays on disk; memory freed on next start)"
                else
                    record_warn "unpin-${rmid}" "admin PUT failed — unpin ${rmid} manually at ${base}/admin"
                fi
                ;;
        esac
    done

    local mid alias pin
    for entry in "${TIER_MODELS[@]}"; do
        mid="$(basename "$(tier_repo "$entry")")"
        alias="$(tier_alias "$entry")"
        pin="$(tier_pin "$entry")"
        if [ ! -d "$(tier_dir "$entry")" ]; then skip "pin-${alias}" "model ${mid} not on disk — skipping"; continue; fi
        # The workhorse: sole resident model, pinned. dflash_ssd_cache=false covers
        # only the DFlash speculative-decoding engine's private cache (DFlash is
        # never engaged by this deployment); the main SSD prefix cache
        # (--paged-ssd-cache-dir) stays ON — its live upstream risk is oMLX #702
        # (the memory guard tracks Metal allocations, not cache RSS).
        if [ "$pin" = "true" ]; then
            body="{\"model_alias\":\"${alias}\",\"is_pinned\":true,\"is_default\":true,\"dflash_ssd_cache\":false}"
        else
            body="{\"model_alias\":\"${alias}\",\"is_pinned\":false,\"is_default\":false,\"ttl_seconds\":900,\"dflash_ssd_cache\":false}"
        fi
        if curl -fsS --max-time 20 -X PUT -b "$cookie_jar" -H "$auth" -H 'Content-Type: application/json' \
            -d "$body" "${base}${admin}/models/${mid}/settings" >/dev/null 2>&1; then
            ok "pin-${alias}" "alias '${alias}' (pinned=${pin}) set for ${mid}"
        else
            record_warn "pin-${alias}" "admin PUT failed for ${mid} — set alias/pin manually at ${base}/admin"
        fi
    done
    # Stray pins LAST (#43): unpin anything still pinned outside the tier
    # lineup, preserving its alias so a deliberate experiment is recognizable —
    # and warn LOUDLY naming each stray, so a reverted experiment is visible
    # rather than silent. ttl_seconds bounds any accidental load of the
    # now-unpinned model. The escape hatch for a deliberate off-lineup pin is
    # doing it after setup (and accepting the next run reverts it), or landing
    # an ADR first — the sole-resident invariant (ADR-009/ADR-010) wins here.
    local smid salias
    while IFS='|' read -r smid salias; do
        [ -n "$smid" ] || continue
        # salias comes from model_settings.json (operator/admin-panel state,
        # not a script constant). Only interpolate it into the JSON body when
        # it is a safe charset; otherwise omit the field — the PUT merges, so
        # the existing alias is left untouched either way.
        case "$salias" in
            (*[!A-Za-z0-9._-]*|"") body="{\"is_pinned\":false,\"ttl_seconds\":900}" ;;
            (*) body="{\"model_alias\":\"${salias}\",\"is_pinned\":false,\"ttl_seconds\":900}" ;;
        esac
        if curl -fsS --max-time 20 -X PUT -b "$cookie_jar" -H "$auth" -H 'Content-Type: application/json' \
            -d "$body" "${base}${admin}/models/${smid}/settings" >/dev/null 2>&1; then
            record_warn "stray-pin" "unpinned STRAY pin on ${smid} (alias '${salias:-none}' kept) — it was outside the ADR-009 lineup; if this was a deliberate experiment, re-pin after setup or land an ADR"
        else
            record_warn "stray-pin" "stray pin on ${smid} could not be unpinned via admin PUT — unpin it manually at ${base}/admin (sole-resident invariant, ADR-009)"
        fi
    done <<< "$(stray_pins)"

    # Stray defaults (#77): the default can sit on an UNPINNED model, so the
    # stray-pin pass above does not clear it. Runs AFTER the workhorse PUT has
    # claimed is_default, so this only ever clears a leftover holder.
    local dmid dalias
    while IFS='|' read -r dmid dalias; do
        [ -n "$dmid" ] || continue
        # dalias is operator/admin-panel state — same charset guard as the
        # stray-pin pass; the PUT merges, so omitting it leaves it untouched.
        case "$dalias" in
            (*[!A-Za-z0-9._-]*|"") body="{\"is_default\":false}" ;;
            (*) body="{\"model_alias\":\"${dalias}\",\"is_default\":false}" ;;
        esac
        if curl -fsS --max-time 20 -X PUT -b "$cookie_jar" -H "$auth" -H 'Content-Type: application/json' \
            -d "$body" "${base}${admin}/models/${dmid}/settings" >/dev/null 2>&1; then
            record_warn "stray-default" "cleared STRAY is_default on ${dmid} (alias '${dalias:-none}') — the default belongs on the pinned workhorse (#77)"
        else
            record_warn "stray-default" "stray is_default on ${dmid} could not be cleared via admin PUT — clear it manually at ${base}/admin (#77)"
        fi
    done <<< "$(stray_defaults)"

    if ! $workhorse_present; then
        record_warn "pin" "workhorse model not on disk — download it with --download-model, then re-run to pin it (any retired-tier memory was still freed this run)"
    fi
    rm -f "$cookie_jar"

    if $started_by_us; then
        if "$CONTROL_PATH" stop >/dev/null 2>&1; then
            ok "pin" "pins applied; server stopped (on-demand end-state restored)"
        else
            record_warn "pin" "pins applied but failed to stop the server — run: omlxctl stop"
        fi
    else
        ok "pin" "pins applied against the already-running server (left running)"
    fi
}

# --- Settings convergence (#42) ---------------------------------------------
# oMLX persists its effective config to ~/.omlx/settings.json. On 0.4.4 the
# persisted values SILENTLY WON over the start wrapper's CLI flags (the
# 2026-07-11 hot_cache_max_size=0 incident: a whole agent session ran with the
# RAM cache tier off). Measured on 0.5.7 (2026-08-15): the precedence is fixed
# upstream — CLI flags win and the file is re-persisted from the effective
# config at each wrapper start — so this gate is REGRESSION INSURANCE plus
# coverage for the window where an admin-panel edit or manual `omlx serve` run
# persisted drift and the wrapper has not started since. The wrapper is the
# single source of truth: expected values are parsed from the INSTALLED
# wrapper at runtime, never duplicated here.
#
# wrapper_flag FLAG — prints the value following FLAG in the installed start
# wrapper, or nothing if the wrapper or flag is absent.
wrapper_flag() {
    local wrapper="$BIN_DIR/omlx-start-wrapper.sh"
    [ -r "$wrapper" ] || return 0
    sed -n "s/^[[:space:]]*$1[[:space:]]\{1,\}\([^\\ ]*\).*/\1/p" "$wrapper" | head -1 | tr -d '"'
}

# settings_converged HOT SSD GUARD CONC — returns 0 when every drift-prone key
# in settings.json is absent/null or equal to the wrapper value. Key paths are
# the oMLX 0.5.7 schema (nested sections); the 0.4.4-era flat/cache shape is
# gone from current files, and an unreadable/absent file counts as converged
# (first-ever start writes it from the CLI flags).
settings_converged() {
    [ -f "$OMLX_HOME/settings.json" ] || return 0
    python3 - "$OMLX_HOME/settings.json" "$1" "$2" "$3" "$4" <<'PYEOF' 2>/dev/null
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)  # unreadable — nothing to converge; first start rewrites it
hot, ssd, guard, conc = sys.argv[2:6]
def get(path):
    cur = d
    for k in path:
        if not isinstance(cur, dict):
            return None
        cur = cur.get(k)
    return cur
def size_drift(actual, expected):
    return expected and actual is not None and str(actual).upper() != expected.upper()
def num_drift(actual, expected):
    try:
        return expected and actual is not None and float(actual) != float(expected)
    except (TypeError, ValueError):
        return True
drift = []
if size_drift(get(("cache", "hot_cache_max_size")), hot):
    drift.append(f"cache.hot_cache_max_size={get(('cache','hot_cache_max_size'))} (wrapper: {hot})")
if size_drift(get(("cache", "ssd_cache_max_size")), ssd):
    drift.append(f"cache.ssd_cache_max_size={get(('cache','ssd_cache_max_size'))} (wrapper: {ssd})")
if num_drift(get(("memory", "memory_guard_custom_ceiling_gb")), guard):
    drift.append(f"memory.memory_guard_custom_ceiling_gb={get(('memory','memory_guard_custom_ceiling_gb'))} (wrapper: {guard})")
if num_drift(get(("scheduler", "max_concurrent_requests")), conc):
    drift.append(f"scheduler.max_concurrent_requests={get(('scheduler','max_concurrent_requests'))} (wrapper: {conc})")
if drift:
    print("; ".join(drift))
    sys.exit(1)
sys.exit(0)
PYEOF
}

# converge_settings — the setup step. Detects drift and repairs it with the
# server STOPPED (a running server rewrites the file from its in-memory state,
# so an edit under it is lost). Repair writes the wrapper values — exactly
# what oMLX itself re-persists at the next wrapper start — never null (the
# nested 0.5.7 schema is not verified to accept nulls).
converge_settings() {
    if [ ! -f "$OMLX_HOME/settings.json" ]; then
        skip "settings" "no settings.json yet — first server start writes it from the wrapper flags"
        return
    fi
    # Guard every assignment: under set -euo pipefail a failing command
    # substitution aborts the script, and this step must never hard-fail (#42).
    local hot ssd guard conc
    hot="$(wrapper_flag --hot-cache-max-size)" || hot=""
    ssd="$(wrapper_flag --paged-ssd-cache-max-size)" || ssd=""
    guard="$(wrapper_flag --memory-guard-gb)" || guard=""
    conc="$(wrapper_flag --max-concurrent-requests)" || conc=""
    if [ -z "$hot$ssd$guard$conc" ]; then
        skip "settings" "installed start wrapper not found/parseable — nothing to converge against"
        return
    fi
    # A PARTIAL parse failure must be loud, not silently skip that one key:
    # an empty expected value disables drift detection for that field only.
    local flagname val
    for flagname in "--hot-cache-max-size:$hot" "--paged-ssd-cache-max-size:$ssd" \
                    "--memory-guard-gb:$guard" "--max-concurrent-requests:$conc"; do
        val="${flagname#*:}"
        [ -z "$val" ] && record_warn "settings" "could not parse ${flagname%%:*} from the installed wrapper — drift detection for that key is OFF this run"
    done
    local drift
    if drift="$(settings_converged "$hot" "$ssd" "$guard" "$conc")"; then
        ok "settings" "settings.json matches the wrapper flags (hot ${hot}, ssd ${ssd}, guard ${guard} GB, concurrency ${conc})"
        return
    fi
    record_warn "settings" "settings.json drift found: ${drift}"
    # TOCTOU note: a server starting between this health probe and the write
    # below could race the repair — accepted on this single-operator host
    # (same accepted window as apply_pins's already-running-server handling).
    if curl -fsS --max-time 3 "http://localhost:${PORT}/health" >/dev/null 2>&1; then
        record_warn "settings" "server is running — a live server rewrites settings.json; stop it (omlxctl stop) and re-run setup to repair"
        return
    fi
    if python3 - "$OMLX_HOME/settings.json" "$hot" "$ssd" "$guard" "$conc" <<'PYEOF' 2>/dev/null
import json, sys
p = sys.argv[1]
d = json.load(open(p))
hot, ssd, guard, conc = sys.argv[2:6]
d.setdefault("cache", {})["hot_cache_max_size"] = hot
d["cache"]["ssd_cache_max_size"] = ssd
d.setdefault("memory", {})["memory_guard_custom_ceiling_gb"] = float(guard)
d.setdefault("scheduler", {})["max_concurrent_requests"] = int(conc)
json.dump(d, open(p, "w"), indent=2)
PYEOF
    then
        chmod 600 "$OMLX_HOME/settings.json" 2>/dev/null || true
        ok "settings" "drifted keys repaired to the wrapper values (server was stopped)"
    else
        record_warn "settings" "automatic repair failed — edit ${OMLX_HOME}/settings.json manually with the server stopped (cache.hot_cache_max_size=${hot}, cache.ssd_cache_max_size=${ssd}, memory.memory_guard_custom_ceiling_gb=${guard}, scheduler.max_concurrent_requests=${conc})"
    fi
}

# --- Validation -------------------------------------------------------------
validate_endpoint() {
    info "Validating endpoint at http://localhost:${PORT}/v1"
    if [ ! -r "$API_KEY_FILE" ]; then
        err "validate" "API key file $API_KEY_FILE not readable — run setup first"; exit 2
    fi
    local key; key="$(cat "$API_KEY_FILE")"
    local base="http://localhost:${PORT}/v1"
    local auth="Authorization: Bearer ${key}"

    # 1. models
    local models
    if models="$(curl -fsS -H "$auth" "${base}/models" 2>/dev/null)"; then
        ok "validate-models" "GET /v1/models reachable"
        detail "$models"
        # The workhorse alias should be registered (single pinned model, ADR-009).
        local entry valias
        for entry in "${TIER_MODELS[@]}"; do
            valias="$(tier_alias "$entry")"
            if echo "$models" | grep -q "$valias"; then
                ok "validate-alias" "alias '${valias}' present"
            else
                record_warn "validate-alias" "alias '${valias}' not found — apply pins (re-run setup) or set it in /admin"
            fi
        done
        # No retired ADR-006 tier should still be pinned — a leftover pin holds
        # ~30-45 GB that the fan-out's KV headroom is supposed to get (ADR-009).
        local r rmid
        for r in "${RETIRED_MODELS[@]}"; do
            rmid="$(basename "$(tier_repo "$r")")"
            if [ "$(retired_model_state "$(tier_repo "$r")")" = "dirty" ]; then
                record_warn "validate-retired" "retired model ${rmid} is still pinned/DFlash-on — re-run setup to free its memory"
            else
                ok "validate-retired" "retired model ${rmid} not pinned"
            fi
        done
    else
        record_err "validate-models" "GET /v1/models failed — is the server running? (launchctl print gui/$(id -u)/${AGENT_LABEL})"
        return
    fi

    # 2. chat completion. Generous max_tokens everywhere: gpt-oss emits a
    # Harmony reasoning channel before the answer/tool call (default effort
    # medium), so tight budgets truncate mid-reasoning (ADR-013; the GLM-era
    # preamble constraint had the same shape).
    local chat_req chat_resp
    chat_req='{"model":"'"$PRIMARY_ALIAS"'","messages":[{"role":"user","content":"Reply with the single word: pong"}],"max_tokens":256}'
    if chat_resp="$(curl -fsS -H "$auth" -H 'Content-Type: application/json' -d "$chat_req" "${base}/chat/completions" 2>/dev/null)"; then
        ok "validate-chat" "POST /v1/chat/completions returned a response"
        detail "$chat_resp"
    else
        record_err "validate-chat" "chat completion request failed"
    fi

    # 3. tool-calling (Harmony format; max_tokens 512 covers the reasoning
    # channel ahead of the call — the #73 battery ran 58/58 at this budget)
    local tool_req tool_resp
    tool_req='{"model":"'"$PRIMARY_ALIAS"'","messages":[{"role":"user","content":"What files are in the current directory? Use the tool."}],"tools":[{"type":"function","function":{"name":"list_dir","description":"List files in a directory","parameters":{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}}}],"tool_choice":"auto","max_tokens":512}'
    if tool_resp="$(curl -fsS -H "$auth" -H 'Content-Type: application/json' -d "$tool_req" "${base}/chat/completions" 2>/dev/null)"; then
        if echo "$tool_resp" | grep -q 'tool_calls'; then
            ok "validate-tools" "model emitted tool_calls markup"
        else
            record_warn "validate-tools" "no tool_calls in response — the orchestrator depends on this; check the tool-call parser config"
        fi
        detail "$tool_resp"
    else
        record_err "validate-tools" "tool-calling request failed"
    fi

    # 4. admission-queueing probe — two parallel requests against the serial
    # mark (--max-concurrent-requests 1, ADR-013): the second MUST queue at
    # admission and then complete, not error. This verifies the serial
    # invariant degrades gracefully when a client misbehaves (double-fired
    # step, stray second client) — the failure mode the mark-1 flag exists to
    # absorb. Both requests completing is the pass condition.
    local pid1 pid2 rc1=0 rc2=0
    curl -fsS -H "$auth" -H 'Content-Type: application/json' -d "$chat_req" "${base}/chat/completions" >/dev/null 2>&1 & pid1=$!
    curl -fsS -H "$auth" -H 'Content-Type: application/json' -d "$chat_req" "${base}/chat/completions" >/dev/null 2>&1 & pid2=$!
    wait "$pid1" || rc1=$?
    wait "$pid2" || rc2=$?
    if [ "$rc1" -eq 0 ] && [ "$rc2" -eq 0 ]; then
        ok "validate-queueing" "2 parallel requests both completed (second queued at admission per the serial mark)"
    else
        record_err "validate-queueing" "queued request failed (rc ${rc1}/${rc2}) — check --max-concurrent-requests and the server logs ($LOG_DIR)"
    fi

    # 5. Anthropic-style messages endpoint (spec requires /v1/messages reachability)
    local msg_req msg_resp
    msg_req='{"model":"'"$PRIMARY_ALIAS"'","max_tokens":256,"messages":[{"role":"user","content":"Reply with the single word: pong"}]}'
    if msg_resp="$(curl -fsS -H "$auth" -H 'Content-Type: application/json' -d "$msg_req" "http://localhost:${PORT}/v1/messages" 2>/dev/null)"; then
        ok "validate-messages" "POST /v1/messages (Anthropic-style) reachable"
        detail "$msg_resp"
    else
        record_warn "validate-messages" "POST /v1/messages failed — Anthropic-style clients need this; confirm the endpoint and whether an 'anthropic-version' header is required"
    fi

    # 6. effective cache mode (#42). Endpoint checks cannot see cache config —
    # the 2026-07-11 hot_cache=0 incident passed every check above while all
    # prefix-cache traffic went to the SSD tier. The discriminator is the
    # hot_cache= field in the running instance's "PagedSSDCacheManager
    # initialized:" startup line: absent means the RAM tier is OFF. (The
    # "paged SSD-only mode" scheduler line appears in healthy runs too and is
    # NOT diagnostic.)
    # Search ALL log files, not the newest by mtime: launchd's out/err logs are
    # two fixed append-only files, and stderr traffic after startup can make
    # the err log "newest" while the banner lives in the out log. Lines carry a
    # sortable timestamp prefix, so sort|tail yields the latest banner across
    # files. Every assignment is ||-guarded: a no-match grep (exit 1) is our
    # anticipated skip path, and pipefail would otherwise abort the script.
    local cache_line
    cache_line="$(grep -h 'PagedSSDCacheManager initialized' "$LOG_DIR"/*.log 2>/dev/null | sort | tail -1)" || cache_line=""
    if [ -z "$cache_line" ]; then
        skip "validate-cache" "no 'PagedSSDCacheManager initialized' line in $LOG_DIR/*.log — cannot verify effective cache mode"
    elif echo "$cache_line" | grep -q 'hot_cache='; then
        ok "validate-cache" "RAM hot-cache tier is ON ($(echo "$cache_line" | grep -o 'hot_cache=[^,]*' || true))"
        detail "$cache_line"
    else
        record_warn "validate-cache" "RAM hot-cache tier is OFF — 'hot_cache=' missing from the cache-manager startup line (the #42 incident signature); stop the server, re-run setup (settings convergence), then restart"
    fi
}

# --- Summary ----------------------------------------------------------------
summary() {
    echo "=================================="
    if [ "$error_count" -eq 0 ]; then
        echo "PASS — ${error_count} errors, ${warn_count} warnings"
        exit 0
    else
        echo "FAIL — ${error_count} errors, ${warn_count} warnings"
        exit 1
    fi
}

# --- Main -------------------------------------------------------------------
main() {
    if $DO_VALIDATE; then
        command -v curl >/dev/null 2>&1 || { err "validate" "curl not found"; exit 2; }
        validate_endpoint
        summary
    fi

    preflight
    if [ ! -d "$TEMPLATE_DIR" ]; then
        err "templates" "template dir not found: $TEMPLATE_DIR — run this script from its repo checkout"; exit 2
    fi
    install_omlx
    ensure_dirs
    ensure_api_key
    install_wired_limit
    install_service
    install_control
    maybe_download_models
    if $DO_CONFIGURE_PI; then
        configure_pi_provider
    else
        skip "pi-config" "Pi provider registration is opt-in — re-run with --configure-pi"
    fi
    apply_pins
    converge_settings

    info "The server is installed but NOT running (startup is intentional)."
    info "Start it on demand:  omlxctl start    (stop: omlxctl stop, status: omlxctl status)"
    info "Then validate with:  $0 --validate"
    summary
}

main
