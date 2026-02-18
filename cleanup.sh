#!/bin/bash
#
# cleanup.sh - Clean up package cache and orphaned packages
# Usage: ./cleanup.sh
#

echo "🧹 ARCH LINUX SYSTEM CLEANUP"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "⚠️  This script needs root privileges. Run with sudo."
    exit 1
fi

# Check current cache size
cache_size=$(du -sh /var/cache/pacman/pkg 2>/dev/null | awk '{print $1}')
echo "📦 Current package cache: $cache_size"
echo ""

# Clean package cache (keep last 3 versions)
echo "🗑️  Cleaning package cache (keeping last 3 versions)..."
paccache -r -k 3
echo ""

# Remove orphaned packages
orphans=$(pacman -Qtdq 2>/dev/null)
if [ -n "$orphans" ]; then
    echo "🔍 Found orphaned packages:"
    echo "$orphans" | sed 's/^/   - /'
    echo ""
    read -p "Remove these orphaned packages? [y/N] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        pacman -Rns --noconfirm $orphans
        echo "✅ Orphaned packages removed"
    else
        echo "⏭️  Skipped orphan removal"
    fi
else
    echo "✨ No orphaned packages found"
fi
echo ""

# Clean journal logs (keep last 7 days)
echo "📋 Cleaning journal logs (keeping last 7 days)..."
journalctl --vacuum-time=7d
echo ""

# Show new cache size
new_cache_size=$(du -sh /var/cache/pacman/pkg 2>/dev/null | awk '{print $1}')
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ Cleanup complete!"
echo "📦 Package cache: $cache_size → $new_cache_size"
