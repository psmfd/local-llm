#!/usr/bin/env bash
# omlx-start-wrapper.sh — start the tuned oMLX inference server under launchd.
#
# Installed by setup-omlx-m5.sh (placeholders substituted at install time). The
# LaunchAgent (com.local.omlx.plist) exec's this script at login. We use a wrapper
# rather than `brew services` because brew services starts omlx with zero-config
# defaults and would not carry the tuned serving flags below.
#
# Placeholders substituted at install time:
#   __BREW_PREFIX__    Homebrew prefix (e.g. /opt/homebrew)
#   __MODEL_DIR__      models root; oMLX auto-discovers models in its subdirs
#   __CACHE_DIR__      paged-SSD cache dir
#   __API_KEY_FILE__   path to the 0600 API-key file
#   __WIRED_MIN_MB__   minimum acceptable iogpu.wired_limit_mb (sanity threshold)
#
# launchd does not source shell profiles and provides only a minimal PATH, so we
# set PATH explicitly and `exec` the server (launchd tracks the direct child PID;
# backgrounding would break KeepAlive).

set -euo pipefail

export PATH="__BREW_PREFIX__/bin:__BREW_PREFIX__/sbin:/usr/bin:/bin:/usr/sbin:/sbin"

warn() { echo "WARN  [wrapper] $*" >&2; }
err()  { echo "ERROR [wrapper] $*" >&2; }

# --- Sanity-check the Metal wired limit -------------------------------------
# The LaunchDaemon should have raised this at boot. If it did not (silent daemon
# failure), the server may OOM when wiring the model — warn loudly but proceed so
# launchd still has a process to supervise.
limit="$(/usr/sbin/sysctl -n iogpu.wired_limit_mb 2>/dev/null || echo 0)"
# shellcheck disable=SC2170 # __WIRED_MIN_MB__ is replaced with an integer by setup-omlx-m5.sh at install time
if [ "${limit:-0}" -lt "__WIRED_MIN_MB__" ]; then
    warn "iogpu.wired_limit_mb=${limit} is below expected __WIRED_MIN_MB__ — large models may fail to wire. Check com.local.iogpu-wired-limit LaunchDaemon."
fi

# --- API key ----------------------------------------------------------------
if [ ! -r "__API_KEY_FILE__" ]; then
    err "API key file __API_KEY_FILE__ not found or unreadable — run setup-omlx-m5.sh first."
    exit 1
fi
api_key="$(cat "__API_KEY_FILE__")"
if [ -z "$api_key" ]; then
    err "API key file __API_KEY_FILE__ is empty."
    exit 1
fi

# --- Start the server -------------------------------------------------------
# NOTE: the exact subcommand/flag spelling should be confirmed against
# `omlx --help`; this wrapper fails loudly (non-zero exit, logged by launchd) if
# an option is wrong, rather than silently mis-starting.
# Absolute path (not bare `omlx`) so the launch is immune to PATH-order hijacking
# of the user-writable Homebrew bin.
# SECURITY NOTE: passing the key via --api-key places it in the process argument
# list (visible to `ps`). TODO: if a future oMLX exposes an env var or file option
# for the key, prefer that over the command-line flag and update ADR-001.
# --memory-guard-gb caps oMLX's Metal allocations below the 96 GB wired ceiling so
# saturation surfaces as server-level backpressure, not Metal wiring failures. It
# replaced the removed --max-process-memory flag (ADR-002); per oMLX #702 it
# monitors Metal allocations, not total RSS.
# --hot-cache-max-size accepts both absolute sizes ('18GB') and percentages
# ('20%'). We pin an absolute 18GB for a deterministic hot-cache footprint
# independent of how oMLX resolves a percentage (≈ 20% of the 90 GB guard).
# --host pins the loopback bind explicitly so "local-only" does not depend on an
# upstream default (one oMLX config class defaults to 0.0.0.0).
exec "__BREW_PREFIX__/bin/omlx" serve \
    --host 127.0.0.1 \
    --model-dir "__MODEL_DIR__" \
    --port 8000 \
    --memory-guard-gb 90 \
    --paged-ssd-cache-dir "__CACHE_DIR__" \
    --hot-cache-max-size 18GB \
    --max-concurrent-requests 16 \
    --api-key "$api_key"
