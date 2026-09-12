# Agent instructions

## User profile (read first, applies to every session)

The user is a DevOps engineer, formerly TypeScript, **without iOS,
Swift, or SwiftUI background**. Native iOS was chosen (ADR-0001)
only because cross-platform frameworks (React Native, Flutter) were
unwanted and Android is not needed — not because the user knows the
stack. Consequences:

- Never assume familiarity with iOS/Swift/Xcode concepts in any
  grilling, decision, or explanation. Explain from a TypeScript /
  DevOps perspective (interfaces ≙ protocols, DI, stubs vs. mocks).
- Tests are the user's primary quality feedback. They must be
  readable without deep Swift knowledge: descriptive names, minimal
  Swift idiom, Given/When/Then comment blocks. On every delivery,
  summarize in plain language what the tests prove and how to read
  red/green output.
- The driving agent translates stack-specific details; the user
  decides product/design questions, not Swift trivia.

## Agent skills

### Issue tracker

GitHub issues via `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Canonical roles: `needs-triage`, `needs-info`, `ready-for-agent`,
`ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context (`CONTEXT.md` + `docs/adr/`). See `docs/agents/domain.md`.
