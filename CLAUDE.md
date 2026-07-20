# formkiq-backend — Development Guidelines

## Git Commits Require Explicit Human Approval (ABSOLUTE)

NEVER `git commit` or `git push` in this repo unless the operator has reviewed the exact staged diff in this session and explicitly approved that specific commit. Plan docs, step prompts, and runbooks saying "commit" mean: stage the change, present the diff, and STOP for sign-off. One approval covers exactly one commit. Full rule: workspace root `CLAUDE.md` → "Git Commits Require Explicit In-Session Human Approval".

> The workspace-root `~/workspace/FotoArca/CLAUDE.md` carries the agent-global conventions and the FormKIQ fork-repository navigation rule (which path to edit vs. the upstream reference). It is **always loaded** alongside this file.
>
> **Organization policy** (see root CLAUDE.md > "CLAUDE.md Documentation Architecture"): keep every CLAUDE.md / rules file under ~40k chars; split topics into `.claude/rules/` with `@import`. This file is the slim entry point for the FormKIQ backend (GraalVM native-image Lambdas + deploy tooling).

## formkiq-backend rules

@.claude/rules/graalvm-architecture.md
