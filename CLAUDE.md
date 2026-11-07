# CLAUDE.md

Read [AGENTS.md](AGENTS.md). It is the only instruction file for this
repository; this pointer exists so agents that look for `CLAUDE.md` find it.

## Checks in Claude web sessions

- In Claude web sessions, `.claude/hooks/session-start.sh` installs the dependencies.
- Run `.claude/hooks/check.sh` before every push and pull request.
- Pushes and pull requests are blocked until it passes on the exact code being pushed.
- Never bypass, skip or weaken checks to get past this gate.
- If a check cannot run, tell the user.
