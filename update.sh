#!/bin/bash
# se-video-tools — top-level update dispatcher
# Usage: se-video-tools update

set -e

SCRIPT_DIR="$(cd "$(dirname "$(python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "${BASH_SOURCE[0]}")")" && pwd)"
GITHUB_RAW_BASE="https://raw.githubusercontent.com/robert-friedland/se-video-tools/main"

usage() {
    echo "Usage: se-video-tools <subcommand>"
    echo ""
    echo "Subcommands:"
    echo "  update    Update all se-video-tools scripts to the latest version"
    exit 1
}

if [ "$1" = "update" ] && [ "${_SE_UPDATED:-}" != "1" ]; then
    # Self-update: download new version, verify non-empty and valid, then replace
    echo "Updating se-video-tools..."
    curl -fsSL "${GITHUB_RAW_BASE}/update.sh" -o "$SCRIPT_DIR/update.sh.tmp"
    [ -s "$SCRIPT_DIR/update.sh.tmp" ] || { echo "Download failed or empty"; rm -f "$SCRIPT_DIR/update.sh.tmp"; exit 1; }
    grep -q '^#!/bin/bash' "$SCRIPT_DIR/update.sh.tmp" || { echo "Download corrupt (unexpected content)"; rm -f "$SCRIPT_DIR/update.sh.tmp"; exit 1; }
    chmod +x "$SCRIPT_DIR/update.sh.tmp"
    mv "$SCRIPT_DIR/update.sh.tmp" "$SCRIPT_DIR/update.sh"
    # Update Claude skills (guard on ~/.claude matches install.sh; || true: file may not
    # exist on GitHub during initial rollout until this PR merges).
    # Keep this list in sync with install.sh's skill block.
    if [ -d "$HOME/.claude" ]; then
        mkdir -p "$HOME/.claude/commands"
        for cmd in ipad-bezel composite-bezel sync-clap sync-visual analyze-video \
                   elevenlabs-tts transcribe build-timeline resolve-phrases \
                   interview-rough-cut se-video-tools organize-onsite; do
            curl -fsSL "${GITHUB_RAW_BASE}/commands/${cmd}.md" \
                -o "$HOME/.claude/commands/${cmd}.md" || true
        done
        echo "Claude skills updated."
    fi
    # Re-exec new version to pick up any changes; _SE_UPDATED prevents infinite loop
    exec env _SE_UPDATED=1 "$SCRIPT_DIR/update.sh" update
fi

if [ "$1" = "update" ]; then
    # Running as re-exec'd new version — update each tool by absolute path
    echo "Updating ipad_bezel..."
    "$SCRIPT_DIR/ipad_bezel.sh" update || { echo "ipad_bezel update failed"; exit 1; }

    echo "Updating composite_bezel..."
    "$SCRIPT_DIR/composite_bezel.sh" update || { echo "composite_bezel update failed"; exit 1; }

    echo "Updating sync_clap..."
    "$SCRIPT_DIR/sync_clap.sh" update || { echo "sync_clap update failed"; exit 1; }

    echo "Updating extract_frames..."
    curl -fsSL "${GITHUB_RAW_BASE}/extract_frames.sh" -o "$SCRIPT_DIR/extract_frames.sh.tmp"
    [ -s "$SCRIPT_DIR/extract_frames.sh.tmp" ] || { echo "extract_frames download failed or empty"; rm -f "$SCRIPT_DIR/extract_frames.sh.tmp"; exit 1; }
    grep -q '^#!/bin/bash' "$SCRIPT_DIR/extract_frames.sh.tmp" || { echo "extract_frames download corrupt"; rm -f "$SCRIPT_DIR/extract_frames.sh.tmp"; exit 1; }
    chmod +x "$SCRIPT_DIR/extract_frames.sh.tmp"
    mv "$SCRIPT_DIR/extract_frames.sh.tmp" "$SCRIPT_DIR/extract_frames.sh"
    echo "✓ extract_frames updated"

    echo "Updating elevenlabs_tts..."
    # Bootstrap: users who installed before elevenlabs_tts existed don't have the file yet.
    if [ ! -f "$SCRIPT_DIR/elevenlabs_tts.sh" ]; then
        curl -fsSL "${GITHUB_RAW_BASE}/elevenlabs_tts.sh" -o "$SCRIPT_DIR/elevenlabs_tts.sh.tmp"
        [ -s "$SCRIPT_DIR/elevenlabs_tts.sh.tmp" ] || { echo "elevenlabs_tts download failed or empty"; rm -f "$SCRIPT_DIR/elevenlabs_tts.sh.tmp"; exit 1; }
        grep -q '^#!/bin/bash' "$SCRIPT_DIR/elevenlabs_tts.sh.tmp" || { echo "elevenlabs_tts download corrupt"; rm -f "$SCRIPT_DIR/elevenlabs_tts.sh.tmp"; exit 1; }
        mv "$SCRIPT_DIR/elevenlabs_tts.sh.tmp" "$SCRIPT_DIR/elevenlabs_tts.sh"
        chmod +x "$SCRIPT_DIR/elevenlabs_tts.sh"
        # Symlink into brew bin so existing installs pick it up on PATH
        BREW_BIN="$(brew --prefix 2>/dev/null)/bin"
        [ -d "$BREW_BIN" ] && ln -sf "$SCRIPT_DIR/elevenlabs_tts.sh" "$BREW_BIN/elevenlabs_tts"
        echo "✓ elevenlabs_tts bootstrapped"
    fi
    "$SCRIPT_DIR/elevenlabs_tts.sh" update || { echo "elevenlabs_tts update failed"; exit 1; }

    echo "Updating transcribe..."
    # Bootstrap: users who installed before transcribe existed don't have the file yet.
    if [ ! -f "$SCRIPT_DIR/transcribe.sh" ]; then
        curl -fsSL "${GITHUB_RAW_BASE}/transcribe.sh" -o "$SCRIPT_DIR/transcribe.sh.tmp"
        [ -s "$SCRIPT_DIR/transcribe.sh.tmp" ] || { echo "transcribe download failed or empty"; rm -f "$SCRIPT_DIR/transcribe.sh.tmp"; exit 1; }
        grep -q '^#!/bin/bash' "$SCRIPT_DIR/transcribe.sh.tmp" || { echo "transcribe download corrupt"; rm -f "$SCRIPT_DIR/transcribe.sh.tmp"; exit 1; }
        mv "$SCRIPT_DIR/transcribe.sh.tmp" "$SCRIPT_DIR/transcribe.sh"
        chmod +x "$SCRIPT_DIR/transcribe.sh"
        BREW_BIN="$(brew --prefix 2>/dev/null)/bin"
        [ -d "$BREW_BIN" ] && ln -sf "$SCRIPT_DIR/transcribe.sh" "$BREW_BIN/transcribe"
        echo "✓ transcribe bootstrapped"
    fi
    "$SCRIPT_DIR/transcribe.sh" update || { echo "transcribe update failed"; exit 1; }
    # whisper-cpp binary is a brew dependency; remind once if missing
    if ! command -v whisper-cli >/dev/null 2>&1; then
        echo "  note: whisper-cli not found — run 'brew install whisper-cpp' to enable transcribe"
    fi

    echo "Updating build_timeline..."
    # Bootstrap: users who installed before build_timeline existed don't have the file yet.
    if [ ! -f "$SCRIPT_DIR/build_timeline.sh" ]; then
        curl -fsSL "${GITHUB_RAW_BASE}/build_timeline.sh" -o "$SCRIPT_DIR/build_timeline.sh.tmp"
        [ -s "$SCRIPT_DIR/build_timeline.sh.tmp" ] || { echo "build_timeline download failed or empty"; rm -f "$SCRIPT_DIR/build_timeline.sh.tmp"; exit 1; }
        grep -q '^#!/bin/bash' "$SCRIPT_DIR/build_timeline.sh.tmp" || { echo "build_timeline download corrupt"; rm -f "$SCRIPT_DIR/build_timeline.sh.tmp"; exit 1; }
        mv "$SCRIPT_DIR/build_timeline.sh.tmp" "$SCRIPT_DIR/build_timeline.sh"
        chmod +x "$SCRIPT_DIR/build_timeline.sh"
        BREW_BIN="$(brew --prefix 2>/dev/null)/bin"
        [ -d "$BREW_BIN" ] && ln -sf "$SCRIPT_DIR/build_timeline.sh" "$BREW_BIN/build_timeline"
        echo "✓ build_timeline bootstrapped"
    fi
    "$SCRIPT_DIR/build_timeline.sh" update || { echo "build_timeline update failed"; exit 1; }

    echo "Updating resolve_phrases..."
    # Bootstrap: users who installed before resolve_phrases existed don't have the file yet.
    if [ ! -f "$SCRIPT_DIR/resolve_phrases.sh" ]; then
        curl -fsSL "${GITHUB_RAW_BASE}/resolve_phrases.sh" -o "$SCRIPT_DIR/resolve_phrases.sh.tmp"
        [ -s "$SCRIPT_DIR/resolve_phrases.sh.tmp" ] || { echo "resolve_phrases download failed or empty"; rm -f "$SCRIPT_DIR/resolve_phrases.sh.tmp"; exit 1; }
        grep -q '^#!/bin/bash' "$SCRIPT_DIR/resolve_phrases.sh.tmp" || { echo "resolve_phrases download corrupt"; rm -f "$SCRIPT_DIR/resolve_phrases.sh.tmp"; exit 1; }
        mv "$SCRIPT_DIR/resolve_phrases.sh.tmp" "$SCRIPT_DIR/resolve_phrases.sh"
        chmod +x "$SCRIPT_DIR/resolve_phrases.sh"
        BREW_BIN="$(brew --prefix 2>/dev/null)/bin"
        [ -d "$BREW_BIN" ] && ln -sf "$SCRIPT_DIR/resolve_phrases.sh" "$BREW_BIN/resolve_phrases"
        echo "✓ resolve_phrases bootstrapped"
    fi
    "$SCRIPT_DIR/resolve_phrases.sh" update || { echo "resolve_phrases update failed"; exit 1; }

    echo "Updating bridge_broll..."
    # Bootstrap: users who installed before bridge_broll existed don't have the file yet.
    if [ ! -f "$SCRIPT_DIR/bridge_broll.sh" ]; then
        curl -fsSL "${GITHUB_RAW_BASE}/bridge_broll.sh" -o "$SCRIPT_DIR/bridge_broll.sh.tmp"
        [ -s "$SCRIPT_DIR/bridge_broll.sh.tmp" ] || { echo "bridge_broll download failed or empty"; rm -f "$SCRIPT_DIR/bridge_broll.sh.tmp"; exit 1; }
        grep -q '^#!/bin/bash' "$SCRIPT_DIR/bridge_broll.sh.tmp" || { echo "bridge_broll download corrupt"; rm -f "$SCRIPT_DIR/bridge_broll.sh.tmp"; exit 1; }
        mv "$SCRIPT_DIR/bridge_broll.sh.tmp" "$SCRIPT_DIR/bridge_broll.sh"
        chmod +x "$SCRIPT_DIR/bridge_broll.sh"
        BREW_BIN="$(brew --prefix 2>/dev/null)/bin"
        [ -d "$BREW_BIN" ] && ln -sf "$SCRIPT_DIR/bridge_broll.sh" "$BREW_BIN/bridge_broll"
        echo "✓ bridge_broll bootstrapped"
    fi
    "$SCRIPT_DIR/bridge_broll.sh" update || { echo "bridge_broll update failed"; exit 1; }

    echo "All tools updated."
    exit 0
fi

usage
