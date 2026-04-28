#!/bin/bash
# treemux-managed v1
# Emit OSC 777 desktop notification for treemux.
# Args:
#   $1 = event kind: "done" | "input"
#   $2 = optional body text
event="${1:-done}"
body="${2:-}"
printf '\033]777;notify;treemux:%s;%s\007' "$event" "$body" > /dev/tty 2>/dev/null
