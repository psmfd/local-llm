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
#   --download-model   Download the model (~32 GB) via `hf download`. Off by default.
#   --configure-pi     Register the oMLX provider with the Pi coding agent.
#                      Auto-writes ~/.pi/agent/models.json ONLY when its
#                      providers object is empty (backup taken first);
#                      otherwise renders ~/.omlx/pi-provider-snippet.json and
#                      prints manual merge steps. No secret is written.
#   --validate         Run endpoint checks against a running server (models,
#                      chat completion, tool-calling, Anthropic endpoint, and
#                      a 2-way concurrency probe) and exit. When combined
#                      with setup flags, validation runs by itself.
#   --verbose          Print verbose detail lines.
#   -h, --help         Show this help and exit.
#
# Exit codes:
#   0  All steps succeeded (warnings are informational only).
#   1  One or more errors occurred.
#   2  Environment or precondition failure (wrong OS/arch, insufficient
#      RAM/disk, Homebrew missing, etc.).
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
MIN_DISK_GB=100         # ~32 GB model plus paged-SSD cache headroom (ADR-004)

# Repo ID verified against the HuggingFace config.json on 2026-06-22 (ADR-004).
# Re-probed before every download, but still confirm the best current model before
# large downloads. The model is a verified text-only coder build
# (Qwen3MoeForCausalLM, no vision_config) → it routes to oMLX's batched LLM engine
# and is concurrency-safe with NO engine override. A single resident model keeps
# the whole KV/prefix-cache budget under the wired ceiling for the fan-out.
PRIMARY_REPO="lmstudio-community/Qwen3-Coder-30B-A3B-Instruct-MLX-8bit"
PRIMARY_DIR="$MODELS_DIR/Qwen3-Coder-30B-A3B-Instruct-MLX-8bit"
PRIMARY_ALIAS="coding-fast"

# Pi coding-agent provider registration (--configure-pi). contextWindow is half
# the model's 262144-token native context (verified config.json, rope_scaling
# null): 16 concurrent sessions at full context would overrun the KV/wired budget
# and collapse prefix-cache reuse (ADR-004).
PI_AGENT_DIR="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}"
PI_CONTEXT_WINDOW=131072
PI_MAX_TOKENS=16384

DAEMON_LABEL="com.local.iogpu-wired-limit"
DAEMON_PLIST="/Library/LaunchDaemons/${DAEMON_LABEL}.plist"
AGENT_LABEL="com.local.omlx"
AGENT_PLIST="$HOME/Library/LaunchAgents/${AGENT_LABEL}.plist"
WRAPPER_PATH="$BIN_DIR/omlx-start-wrapper.sh"

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

    if sudo launchctl print "system/${DAEMON_LABEL}" >/dev/null 2>&1; then
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
    for flag in --host --model-dir --port --memory-guard-gb --paged-ssd-cache-dir --hot-cache-max-size --max-concurrent-requests --api-key; do
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

    # Do not start the service if the binary is missing — it would only crash-loop
    # under KeepAlive. The config is installed; starting waits until omlx exists.
    if ! $OMLX_PRESENT; then
        record_warn "agent" "omlx not installed — LaunchAgent configured but not started; re-run after installing omlx"
        return
    fi
    if ! check_omlx_cli "$prefix"; then
        return
    fi

    if launchctl print "gui/$(id -u)/${AGENT_LABEL}" >/dev/null 2>&1; then
        if $svc_changed; then
            launchctl bootout "gui/$(id -u)/${AGENT_LABEL}" 2>/dev/null || true
            if launchctl bootstrap "gui/$(id -u)" "$AGENT_PLIST"; then
                ok "agent" "reloaded LaunchAgent (wrapper or plist changed)"
            else
                record_err "agent" "launchctl bootstrap (reload) failed"
            fi
        else
            skip "agent" "LaunchAgent already loaded"
        fi
    else
        if launchctl bootstrap "gui/$(id -u)" "$AGENT_PLIST"; then
            ok "agent" "LaunchAgent bootstrapped (autostarts at login)"
        else
            record_err "agent" "launchctl bootstrap gui failed"
        fi
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
        skip "model" "download is opt-in — re-run with --download-model, or use the /admin downloader (verify the exact quant tags first)"
        return
    fi
    download_model "$PRIMARY_REPO" "$PRIMARY_DIR" "model"
}

# --- Step: Pi coding-agent provider registration (--configure-pi) -----------
# ~/.pi/agent/models.json is hand-edited JSONC inside a version-controlled
# repo; a programmatic merge (jq/python3) would strip its comments. The only
# auto-write case is the provably safe one: file absent, or a comment-stripped
# parse shows an empty providers object (backup taken first; git covers the
# rest). Anything else gets the rendered snippet plus manual merge steps.
print_pi_settings_instructions() {
    local settings_file="$1" primary_id="$2"
    # settings.json is hand-curated and git-tracked; never edited automatically.
    info "To surface the model in Pi's picker, add to the enabledModels array in $settings_file:"
    echo "      \"omlx/${primary_id}\""
    echo "      Select with: pi --model omlx/${primary_id}  (or /model in a session — models.json reloads on /model)"
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
    local primary_id
    primary_id="$(basename "$PRIMARY_DIR")"

    if render_template "$TEMPLATE_DIR/pi-models-omlx.json" "$snippet_dest" \
        "__PORT__"              "$PORT" \
        "__API_KEY_FILE__"      "$API_KEY_FILE" \
        "__PRIMARY_ID__"        "$primary_id" \
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
        print_pi_settings_instructions "$settings_file" "$primary_id"
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

    print_pi_settings_instructions "$settings_file" "$primary_id"
}

# --- Pin/alias instructions (GUI-only; cannot be scripted) ------------------
print_pin_instructions() {
    # Printed unconditionally (not via detail/--verbose): pinning is GUI-only and
    # cannot be scripted, so these are required manual steps, not optional detail.
    info "Model pin + alias is admin-panel only (not a CLI flag). Manual steps:"
    echo "      1. Ensure the server is running, then open http://localhost:${PORT}/admin"
    echo "      2. Under Models, set the alias for $(basename "$PRIMARY_DIR") to '${PRIMARY_ALIAS}' and PIN it (keeps it resident)."
    echo "      The alias persists in ${OMLX_HOME}/settings.json and appears in GET /v1/models."
    echo "      No engine override is needed — the model is text-only (Qwen3MoeForCausalLM); ADR-004."
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
        if echo "$models" | grep -q "$PRIMARY_ALIAS"; then
            ok "validate-alias" "alias '${PRIMARY_ALIAS}' present"
        else
            record_warn "validate-alias" "alias '${PRIMARY_ALIAS}' not found — pin it in /admin"
        fi
    else
        record_err "validate-models" "GET /v1/models failed — is the server running? (launchctl print gui/$(id -u)/${AGENT_LABEL})"
        return
    fi

    # 2. chat completion
    local chat_req chat_resp
    chat_req='{"model":"'"$PRIMARY_ALIAS"'","messages":[{"role":"user","content":"Reply with the single word: pong"}],"max_tokens":16}'
    if chat_resp="$(curl -fsS -H "$auth" -H 'Content-Type: application/json' -d "$chat_req" "${base}/chat/completions" 2>/dev/null)"; then
        ok "validate-chat" "POST /v1/chat/completions returned a response"
        detail "$chat_resp"
    else
        record_err "validate-chat" "chat completion request failed"
    fi

    # 3. tool-calling
    local tool_req tool_resp
    tool_req='{"model":"'"$PRIMARY_ALIAS"'","messages":[{"role":"user","content":"What files are in the current directory? Use the tool."}],"tools":[{"type":"function","function":{"name":"list_dir","description":"List files in a directory","parameters":{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}}}],"tool_choice":"auto","max_tokens":128}'
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

    # 4. concurrency probe — two parallel completions confirm the batched LLM
    # engine handles the fan-out this project exists to serve. A single-stream
    # check cannot detect a server that serializes or fails under concurrency.
    local pid1 pid2 rc1=0 rc2=0
    curl -fsS -H "$auth" -H 'Content-Type: application/json' -d "$chat_req" "${base}/chat/completions" >/dev/null 2>&1 & pid1=$!
    curl -fsS -H "$auth" -H 'Content-Type: application/json' -d "$chat_req" "${base}/chat/completions" >/dev/null 2>&1 & pid2=$!
    wait "$pid1" || rc1=$?
    wait "$pid2" || rc2=$?
    if [ "$rc1" -eq 0 ] && [ "$rc2" -eq 0 ]; then
        ok "validate-concurrent" "2 parallel completions succeeded (batched engine handles concurrency)"
    else
        record_err "validate-concurrent" "parallel completions failed (rc ${rc1}/${rc2}) — check --max-concurrent-requests and the server logs ($LOG_DIR)"
    fi

    # 5. Anthropic-style messages endpoint (spec requires /v1/messages reachability)
    local msg_req msg_resp
    msg_req='{"model":"'"$PRIMARY_ALIAS"'","max_tokens":16,"messages":[{"role":"user","content":"Reply with the single word: pong"}]}'
    if msg_resp="$(curl -fsS -H "$auth" -H 'Content-Type: application/json' -d "$msg_req" "http://localhost:${PORT}/v1/messages" 2>/dev/null)"; then
        ok "validate-messages" "POST /v1/messages (Anthropic-style) reachable"
        detail "$msg_resp"
    else
        record_warn "validate-messages" "POST /v1/messages failed — Anthropic-style clients need this; confirm the endpoint and whether an 'anthropic-version' header is required"
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
    maybe_download_models
    if $DO_CONFIGURE_PI; then
        configure_pi_provider
    else
        skip "pi-config" "Pi provider registration is opt-in — re-run with --configure-pi"
    fi
    print_pin_instructions

    info "Done. Validate with: $0 --validate"
    summary
}

main
