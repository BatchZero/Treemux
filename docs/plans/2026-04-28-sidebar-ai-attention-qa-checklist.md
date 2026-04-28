# Sidebar AI Attention — Manual QA Checklist

For human reviewer to step through after the branch lands. Items map to design.md "Edge Cases" + plan T21.

## Visual

- [ ] Single-tab workspace with running session: project dot is **steady amber**, no pulse.
- [ ] Multi-tab workspace: tab bar shows; each tab has its own dot if its sessions are running.
- [ ] Workspace with no sessions: no dot in sidebar, no dot on any tab.
- [ ] After all tabs closed: sidebar dot disappears for that workspace.

## OSC trigger

- [ ] In any pane: `printf '\033]777;notify;treemux:done;\007' > /dev/tty` causes the project dot to **pulse** quickly.
- [ ] Same with `treemux:input`. Dot pulses identically (T19+ may distinguish later).
- [ ] Sidebar dot AND the affected tab's dot pulse together when in a multi-tab workspace.
- [ ] Clicking the affected pane stops the pulse immediately.
- [ ] Switching to another tab does NOT clear pulse on the originating tab (until that tab is selected and its pane focused).

## Hook install — Local

- [ ] Settings → AI Activity Hints shows the master toggle (default ON).
- [ ] Local section appears only when at least one of `~/.claude/settings.json`, `~/.codex/config.toml`, `~/.config/opencode/config.json` exists. Run `claude`, `codex`, or `opencode` once if needed.
- [ ] For a detected, not-installed agent, clicking Install opens the **diff preview sheet** showing current + proposed file contents side-by-side.
- [ ] Clicking Apply writes the files (verify by reading e.g. `~/.claude/settings.json`).
- [ ] Status flips to Installed (✅) on next refresh.
- [ ] Clicking Remove restores the original file (only the treemux-managed entry is removed).

## Hook install — Remote

- [ ] Add an SSH workspace in treemux. Settings shows that host as a separate group.
- [ ] Inspecting the remote target requires SSH connectivity (no password prompt — uses `BatchMode=yes`).
- [ ] Install on the remote writes to `<remote-host>:~/.claude/settings.json` and `~/.treemux/hooks/notify.sh`. Verify via `ssh <host> 'cat ~/.claude/settings.json'`.

## Banner

- [ ] Run `claude` in a workspace where Claude is detected but not yet installed. The yellow banner appears above the tab bar.
- [ ] `Preview & Install` opens the same diff preview sheet, Apply installs.
- [ ] `Not Now` dismisses for the current launch (banner doesn't reappear until app restart).
- [ ] `Don't ask for this host` persists; on restart, banner stays hidden for that workspace+agent pair.

## Edge cases

- [ ] Manually edit `~/.claude/settings.json` to remove only `command` from a managed entry. Settings panel shows status `Modified by user` with `Repair` button. Repair restores correctly.
- [ ] Master toggle OFF → no banner ever appears, no sidebar pulse on OSC.
- [ ] Codex with existing user `notify = ["my-program"]` line → install fails with a clear error message rather than silently overwriting.

## Localization

- [ ] Switch app language to 简体中文. All Settings → AI Activity Hints labels and the banner show in Chinese with correct accents.

## Stability

- [ ] All unit tests pass.
- [ ] App build succeeds with no localization-related warnings.
