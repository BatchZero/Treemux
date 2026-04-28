#!/bin/bash
# treemux-managed v1
# Codex passes the event JSON as the last argv. Map to done/input and forward.
event_json="${1:-}"
case "$event_json" in
    *'"type":"agent-turn-tool-call-approval'*) kind=input ;;
    *'"type":"agent-turn-complete"'*)          kind=done  ;;
    *)                                          kind=done  ;;
esac
exec "$HOME/.treemux/hooks/notify.sh" "$kind"
