#!/bin/bash
#
# check-services.sh - Check status of common homelab services
# Usage: ./check-services.sh
#

echo "🔧 SERVICE STATUS CHECK"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Common homelab services to check
SERVICES=(
    "sshd"
    "docker"
    "nginx"
    "apache2"
    "httpd"
    "postgresql"
    "mariadb"
    "mysql"
    "redis"
    "fail2ban"
)

# Function to check service status
check_service() {
    local service=$1
    
    if systemctl list-unit-files | grep -q "^${service}.service"; then
        if systemctl is-active --quiet "$service"; then
            echo "✅ $service: Running"
        else
            echo "❌ $service: Stopped"
        fi
    fi
}

# Check each service
echo "📋 Checking services..."
echo ""

active_count=0
for service in "${SERVICES[@]}"; do
    if systemctl list-unit-files | grep -q "^${service}.service"; then
        check_service "$service"
        if systemctl is-active --quiet "$service"; then
            ((active_count++))
        fi
    fi
done

# Show failed services
echo ""
echo "⚠️  Failed services:"
failed=$(systemctl --failed --no-pager --no-legend | wc -l)
if [ "$failed" -gt 0 ]; then
    systemctl --failed --no-pager --no-legend | awk '{print "   - " $1}'
else
    echo "   None"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📊 Summary: $active_count services running, $failed failed"
