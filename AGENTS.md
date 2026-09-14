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

## Version decisions need fresh facts

Before pinning any version (Xcode, iOS deployment target,
dependencies, CLI tools), verify currency and compatibility via
a research agent (routing per global `~/.pi/agent/AGENTS.md`) or
Context7. No version decision from model memory alone.

## Pull-Request-Review: CodeRabbit (immer einbeziehen)

CodeRabbit (GitHub App) reviewt automatisch jeden Pull Request in diesem
Repo. Das gehört fest zum Prozess:

- **Vor jedem Merge** CodeRabbit-Findings abrufen und abarbeiten:
  `gh api repos/:owner/:repo/pulls/<N>/comments` (Zeilenkommentare) plus
  PR-Review-Zusammenfassung auf der PR-Seite.
- Jedes Finding ist entweder zu **beheben** (Fix-Commit im selben PR)
  oder zu **beantworten/begründen** (PR-Kommentar), bevor gemergt wird.
- CodeRabbit kennt die ADRs nicht: Es kann Verstöße gegen dokumentierte
  Standards (z. B. ADR-0006 Swift Testing, Ticket #9) NICHT als solche
  erkennen — seine Findings sind Hilfsmittel, nicht Ersatz für die
  zwei-Achsen-Review (Standards + Spec, siehe `/code-review`).
- Bekanntes Beispiel: PR #10/#12 — CodeRabbit beschrieb den XCTest-Code
  positiv, ohne den ADR-0006-Verstoß zu erkennen.

## Agent skills

### Issue tracker

GitHub issues via `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Canonical roles: `needs-triage`, `needs-info`, `ready-for-agent`,
`ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context (`CONTEXT.md` + `docs/adr/`). See `docs/agents/domain.md`.
