## Must-Follow Implementation Rules

1. Keep scope tight  
Only implement what was requested. No unrelated refactors.

2. Prioritize router safety  
Use POSIX ash-compatible shell only; avoid non-stock dependencies.

3. Preserve deployment integrity  
Do not require editing installed source for config; use env vars/runtime overrides.

4. Follow Merlin conventions  
Use `cru` for scheduling and keep `services-start` entries simple, tagged, and removable.

5. Verify before handoff  
Run `shellcheck` on changed scripts and keep docs aligned with actual router workflow.
