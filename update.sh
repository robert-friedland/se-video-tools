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
    # Update Claude skill (guard on ~/.claude matches install.sh; || true: file may not
    # exist on GitHub during initial rollout until this PR merges)
    if [ -d "$HOME/.claude" ]; then
        mkdir -p "$HOME/.claude/commands"
        curl -fsSL "${GITHUB_RAW_BASE}/commands/se-video-tools.md" \
            -o "$HOME/.claude/commands/se-video-tools.md" || true
        curl -fsSL "${GITHUB_RAW_BASE}/commands/sync-visual.md" \
            -o "$HOME/.claude/commands/sync-visual.md" || true
        curl -fsSL "${GITHUB_RAW_BASE}/commands/analyze-video.md" \
            -o "$HOME/.claude/commands/analyze-video.md" || true
        curl -fsSL "${GITHUB_RAW_BASE}/commands/organize-onsite.md" \
            -o "$HOME/.claude/commands/organize-onsite.md" || true
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

    echo "All tools updated."
    exit 0
fi

usage
