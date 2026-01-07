#!/bin/bash
# =============================================================================
# Ralph Loop - Notification Utilities
# =============================================================================
# Cross-platform desktop/terminal notifications.
#
# Behaviour:
#   - Controlled by ENABLE_NOTIFICATIONS (true/false, default: false)
#   - Uses NOTIFICATION_LOG (optional) for test-friendly logging in fallback
#   - Prefers:
#       1. macOS: osascript (Notification Center)
#       2. Linux: notify-send
#       3. Fallback: terminal bell + optional log entry
# =============================================================================

# Send a user-visible notification if notifications are enabled.
#
# Arguments:
#   $1 - title
#   $2 - message
send_notification() {
    local title="$1"
    local message="$2"

    # Notifications are opt-in to avoid surprising users.
    if [[ "${ENABLE_NOTIFICATIONS:-false}" != "true" ]]; then
        return 0
    fi

    # macOS Notification Center
    if command -v osascript >/dev/null 2>&1; then
        # Basic notification; quoting kept simple for portability.
        osascript -e "display notification \"$message\" with title \"$title\"" >/dev/null 2>&1 || true
        return 0
    fi

    # Linux notify-send
    if command -v notify-send >/dev/null 2>&1; then
        notify-send "$title" "$message" >/dev/null 2>&1 || true
        return 0
    fi

    # Fallback: terminal bell + optional log entry
    local notification_log="${NOTIFICATION_LOG:-}"
    printf '\a' 2>/dev/null || true
    if [[ -n "$notification_log" ]]; then
        mkdir -p "$(dirname "$notification_log")"
        echo "BELL: $title - $message" >> "$notification_log"
    fi
}