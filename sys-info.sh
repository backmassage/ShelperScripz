#!/bin/bash
#
# sys-info.sh - Quick system information summary
# Usage: ./sys-info.sh
#

echo "🖥️  ARCH LINUX SYSTEM INFORMATION"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Hostname and uptime
echo "📍 Hostname: $(hostname)"
echo "⏱️  Uptime: $(uptime -p)"
echo ""

# CPU info
echo "🔧 CPU:"
cpu_model=$(grep "model name" /proc/cpuinfo | head -1 | cut -d: -f2 | xargs)
cpu_cores=$(nproc)
echo "   Model: $cpu_model"
echo "   Cores: $cpu_cores"
echo "   Load: $(cat /proc/loadavg | awk '{print $1, $2, $3}')"
echo ""

# Memory
echo "💾 Memory:"
free -h | awk 'NR==2{printf "   Total: %s\n   Used: %s\n   Free: %s\n", $2, $3, $4}'
echo ""

# Disk usage
echo "💿 Disk Usage:"
df -h / | awk 'NR==2{printf "   Root: %s / %s (%s used)\n", $3, $2, $5}'
echo ""

# Network
echo "🌐 Network:"
ip -4 addr show | grep inet | grep -v "127.0.0.1" | awk '{print "   " $NF ": " $2}' | head -3
echo ""

# Kernel & OS
echo "⚙️  System:"
echo "   Kernel: $(uname -r)"
echo "   Arch: $(uname -m)"
echo ""

# Package count
pkg_count=$(pacman -Q | wc -l)
echo "📦 Packages: $pkg_count installed"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
