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

## Pull-request review: CodeRabbit (mandatory)

CodeRabbit (GitHub App) automatically reviews every pull request in this
repo. This is a fixed part of the process:

- **Before every merge**, fetch and work through CodeRabbit findings:
  `gh api repos/:owner/:repo/pulls/<N>/comments` (inline comments) plus
  the PR review summary on the PR page.
- Every finding must either be **fixed** (fix commit in the same PR) or
  **answered/justified** (PR comment) before merging.
- CodeRabbit does not know the ADRs: it cannot recognize violations of
  documented standards (e.g. ADR-0006 Swift Testing, ticket #9) as such —
  its findings are an aid, not a replacement for the two-axis review
  (Standards + Spec, see `/code-review`).
- Known example: PR #10/#12 — CodeRabbit described the XCTest code
  positively without recognizing the ADR-0006 violation.

## Agent skills

### Issue tracker

GitHub issues via `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Canonical roles: `needs-triage`, `needs-info`, `ready-for-agent`,
`ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context (`CONTEXT.md` + `docs/adr/`). See `docs/agents/domain.md`.
