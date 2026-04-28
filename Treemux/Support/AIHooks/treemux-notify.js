// treemux-managed v1
// Opencode plugin: forwards session.idle and permission.requested events to
// the shared OSC notify helper so treemux can show a sidebar/tab indicator.
import { execSync } from "node:child_process"

function notify(kind) {
    try {
        execSync(`"$HOME/.treemux/hooks/notify.sh" ${kind}`, { stdio: "ignore" })
    } catch (_) {
        // best-effort; silently ignore if the helper is missing
    }
}

export default {
    "session.idle":         () => notify("done"),
    "permission.requested": () => notify("input"),
}
