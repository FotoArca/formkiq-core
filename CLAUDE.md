# formkiq-backend — Development Guidelines

## Git Commits Require Explicit Human Approval (ABSOLUTE)

NEVER `git commit` or `git push` in this repo unless the operator has reviewed the exact staged diff in this session and explicitly approved that specific commit. Plan docs, step prompts, and runbooks saying "commit" mean: stage the change, present the diff, and STOP for sign-off. One approval covers exactly one commit. Merges and pushes: one approval of a task branch's merge lands the whole branch (merge, push, branch delete, and the `master` → aws-line forward merge + push); full rule: root `CLAUDE.md` → "One merge approval lands the whole branch". Full rule: workspace root `CLAUDE.md` → "Git Commits Require Explicit In-Session Human Approval".

**Exception — comment-only and test-only commits are pre-approved (operator decision 2026-10-15).** A commit whose every hunk only changes code comments, and/or only touches test files (`*.spec.*`, `*.test.*`, test targets, fixtures only tests use), may be committed without review once its checks pass (type-check / the changed tests). Landing it (merge + push) still needs the one merge approval. Anything else in the diff (code, docs, config, lockfiles, comment directives such as `eslint-disable` / `@ts-ignore`) brings back the full rule. Full rule: workspace root `CLAUDE.md` → "Git Commits Require Explicit In-Session Human Approval".

> The workspace-root `~/workspace/FotoArca/CLAUDE.md` carries the agent-global conventions and the FormKIQ fork-repository navigation rule (which path to edit vs. the upstream reference). It is **always loaded** alongside this file.
>
> **Organization policy** (see root CLAUDE.md > "CLAUDE.md Documentation Architecture"): keep every CLAUDE.md / rules file under ~40k chars; split topics into `.claude/rules/` with `@import`. This file is the slim entry point for the FormKIQ backend (GraalVM native-image Lambdas + deploy tooling).

## formkiq-backend rules

@.claude/rules/graalvm-architecture.md
