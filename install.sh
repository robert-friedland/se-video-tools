#!/bin/bash
# se-video-tools installer
# Usage: curl -fsSL <raw-url>/install.sh | bash

set -e

GITHUB_RAW_BASE="https://raw.githubusercontent.com/robert-friedland/se-video-tools/main"
INSTALL_DIR="$HOME/.se-video-tools"
SKILL_DIR="$HOME/.claude/commands"

echo "Installing se-video-tools..."
echo ""

# Homebrew required for ffmpeg
if ! command -v brew &>/dev/null; then
    echo "Homebrew not found — installing..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

# ffmpeg required for video processing
if ! command -v ffmpeg &>/dev/null; then
    echo "Installing ffmpeg..."
    brew install ffmpeg
else
    echo "✓ ffmpeg already installed"
fi

# Create install directory
mkdir -p "$INSTALL_DIR"

# Download script and bezel asset
echo "Downloading ipad_bezel..."
curl -fsSL "${GITHUB_RAW_BASE}/ipad_bezel.sh" -o "$INSTALL_DIR/ipad_bezel.sh"
curl -fsSL "${GITHUB_RAW_BASE}/iPad%20mini%20-%20Starlight%20-%20Portrait.png" \
    -o "$INSTALL_DIR/iPad mini - Starlight - Portrait.png"
chmod +x "$INSTALL_DIR/ipad_bezel.sh"

# Symlink into Homebrew's bin so it's on PATH without any shell config changes
BREW_BIN="$(brew --prefix)/bin"
ln -sf "$INSTALL_DIR/ipad_bezel.sh" "$BREW_BIN/ipad_bezel"
echo "✓ ipad_bezel installed → $BREW_BIN/ipad_bezel"

# Install Claude Code skill if Claude is present
if [ -d "$HOME/.claude" ]; then
    mkdir -p "$SKILL_DIR"
    curl -fsSL "${GITHUB_RAW_BASE}/commands/ipad-bezel.md" \
        -o "$SKILL_DIR/ipad-bezel.md"
    echo "✓ Claude /ipad-bezel skill installed"
else
    echo "  Claude Code not detected — skipping skill install"
fi

echo ""
echo "All done! Usage:"
echo "  ipad_bezel <input.mp4>              # add bezel"
echo "  ipad_bezel update                   # pull latest version"
echo "  /ipad-bezel  (in Claude Code)       # let Claude drive it"
