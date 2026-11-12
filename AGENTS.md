# Build/deploy workflow

- Build/deploy only via subagents `iptvs-build` / `iptvs-deploy`.
- The main session does not run `flutter build`, packaging or copy commands itself:
  it asks for targets, invokes the agent, and reads the report.
- Pass all targets of the current stage at once (`windows` / `android` / `linux`).
  The build agent runs them in one invocation; do not return to the main session
  between targets.
- `CLAUDE.md` remains the source of truth for commands, the verification gate and
  platform-specific rules.
- Deploy: check whether `iptvs.exe` is running (`Get-Process iptvs`). If it is, do not kill
  it — rename locked files to `<name>.old.<timestamp>`, copy the new ones, and remind the
  user to restart. Close the process only if renaming is impossible and the user agrees.
