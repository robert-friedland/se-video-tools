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

# Download composite_bezel script (shares the bezel PNG already downloaded above)
echo "Downloading composite_bezel..."
curl -fsSL "${GITHUB_RAW_BASE}/composite_bezel.sh" -o "$INSTALL_DIR/composite_bezel.sh"
chmod +x "$INSTALL_DIR/composite_bezel.sh"
ln -sf "$INSTALL_DIR/composite_bezel.sh" "$BREW_BIN/composite_bezel"
echo "✓ composite_bezel installed → $BREW_BIN/composite_bezel"

# Download composite_bezel_gpu binary (Apple Silicon GPU compositor)
BINARY_URL="https://github.com/robert-friedland/se-video-tools/releases/latest/download/composite_bezel_gpu"
echo "Downloading composite_bezel_gpu (GPU accelerator)..."
curl -fL "$BINARY_URL" -o "$INSTALL_DIR/composite_bezel_gpu" && {
    chmod +x "$INSTALL_DIR/composite_bezel_gpu"
    codesign -s - "$INSTALL_DIR/composite_bezel_gpu"
    xattr -d com.apple.quarantine "$INSTALL_DIR/composite_bezel_gpu" 2>/dev/null || true
    ln -sf "$INSTALL_DIR/composite_bezel_gpu" "$BREW_BIN/composite_bezel_gpu"
    echo "✓ composite_bezel_gpu installed → $BREW_BIN/composite_bezel_gpu"
} || echo "  composite_bezel_gpu not available (Intel Mac or GitHub Release not yet published — CPU fallback active)"

# Download sync_clap script
echo "Downloading sync_clap..."
curl -fsSL "${GITHUB_RAW_BASE}/sync_clap.sh" -o "$INSTALL_DIR/sync_clap.sh"
chmod +x "$INSTALL_DIR/sync_clap.sh"
ln -sf "$INSTALL_DIR/sync_clap.sh" "$BREW_BIN/sync_clap"
echo "✓ sync_clap installed → $BREW_BIN/sync_clap"

# Install Claude Code skills if Claude is present
if [ -d "$HOME/.claude" ]; then
    mkdir -p "$SKILL_DIR"
    curl -fsSL "${GITHUB_RAW_BASE}/commands/ipad-bezel.md" \
        -o "$SKILL_DIR/ipad-bezel.md"
    echo "✓ Claude /ipad-bezel skill installed"
    curl -fsSL "${GITHUB_RAW_BASE}/commands/composite-bezel.md" \
        -o "$SKILL_DIR/composite-bezel.md"
    echo "✓ Claude /composite-bezel skill installed"
    curl -fsSL "${GITHUB_RAW_BASE}/commands/sync-clap.md" \
        -o "$SKILL_DIR/sync-clap.md"
    echo "✓ Claude /sync-clap skill installed"
else
    echo "  Claude Code not detected — skipping skill install"
fi

echo ""
echo "All done! Usage:"
echo "  ipad_bezel <input.mp4>                          # add bezel overlay"
echo "  composite_bezel <bg.mp4> <screen.mp4>           # composite bezel over background"
echo "  sync_clap <bg.mp4> <screen.mp4>                 # detect clap sync offset"
echo "  ipad_bezel update / composite_bezel update      # pull latest versions"
echo "  sync_clap update                                 # pull latest sync_clap"
echo "  /ipad-bezel  /composite-bezel  /sync-clap  (Claude Code)   # let Claude drive it"
