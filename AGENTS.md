# wadjet

A customisable, macOS-native screenshot and screen-recording utility, in the spirit of ShareX. Swift, macOS 26+.

## Build and run

The app lives in `apps/macos` (SwiftPM, one Swift target). `apps/macos/run.sh` builds,
signs and launches `build/Wadjet.app`; `WADJET_NO_OPEN=1` skips launching (CI's path).
`apps/macos/tools/cmd.sh <command>` posts a debug command to the running app via
DistributedNotificationCenter — see `apps/macos/README.md` for the command list.
Logs land in `~/Library/Application Support/wadjet/app.log`.

## Agent skills

### Issue tracker

Issues live in GitHub Issues on the public repo mia-cx/wadjet. See `docs/agents/issue-tracker.md`.

### Triage labels

Default canonical labels (`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`). See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: `CONTEXT.md` and `docs/adr/` at the repo root. See `docs/agents/domain.md`.
