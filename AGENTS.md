# AGENTS.md

Guidance for AI coding agents working in this repository.

## What this repo is

Public demo code: safe, auditable scripts for removing a Cloudflare account via
the API, in two languages that must stay in behavioral parity.

- Bash (in `bash/`): `precheck.sh`, `leave-account.sh`, `delete-account.sh` (+ `common.sh`, `config.example.sh`; local-only `config.sh`)
- PowerShell 7+ (in `powershell/`): `precheck.ps1`, `leave-account.ps1`, `delete-account.ps1` (+ `common.ps1`, `config.example.ps1`; local-only `config.ps1`)

Customer-facing doc: `README.md`. Dev tool: `powershell/.syntax-check.ps1` (PowerShell parse check; PSScriptRoot-relative, cwd-independent).

## Critical rules

1. **Never execute destructive API calls.** `bash/delete-account.sh --execute` /
   `powershell/delete-account.ps1 -Execute` permanently delete an account. Only a human runs them, only
   after reviewing precheck output, and only against a throwaway account. Dry runs (the default) and
   precheck are GET-only by construction — safe to run with real credentials against throwaway
   accounts at the operator's explicit request. Smoke-test failure paths with fake credentials.
2. **Typed confirmations are load-bearing.** The `LEAVE` gate and the full 32-character account-ID
   gate must never be weakened, automated, or bypassed (no default answers, no piped input).
   Enforced in code: bash reads `/dev/tty`; PowerShell aborts on `[Console]::IsInputRedirected`
   or non-`[Environment]::UserInteractive`. **The account-ID gate runs before the first
   mutation**, not just before the account delete: the cleanup phases destroy Gateway policies
   and the whole Access organization, so a wrong target has to be caught before Phase 0. Never
   move the gate later in the sequence.
3. **Exact-name matching only, and duplicates abort.** Account lookups use `==` (bash) / `-ceq`
   (PowerShell) against the full name. Never weaken to partial, prefix, or fuzzy matching —
   lookalike production account names are the main hazard this repo guards against. Cloudflare
   does not enforce unique account names either, so two exact matches must abort with both IDs
   listed; never fall back to the first match.
4. **"Cannot see" is never "nothing there".** A non-200 on any inventory (zones, logpush,
   gateway, Access, subscriptions, members) must be surfaced as unreadable and must abort an
   execute run — never rendered as "none", never silently skipped. Otherwise a credential
   lacking Logpush:Read deletes an account whose logpush jobs keep shipping logs, which is
   exactly the outcome the docs warn about.
5. **Safety patterns must survive every edit:** dry-run default with explicit `--execute` /
   `-Execute` opt-in, typed account-ID gate before any mutation, Phase 0 subscription gate
   (abort if active subs are visible *or* if the list is unreadable, unless the operator sets
   `BILLING_VERIFIED=1`), cleanup phases (1-3) asserting 200/404 and not `success:false` before
   the irreversible delete, verification step after every mutation with a non-zero exit when the
   resource survives, read-only precheck that inspects all pre-deletion resources.
6. **No secrets, no real customer or account names in committed files.** This repo is public. A
   real customer name was scrubbed before publishing — do not reintroduce one. `bash/config.sh`
   and `powershell/config.ps1` are gitignored; keep credentials in them, never in scripts or
   chat history.

## Doc-accuracy rule

API behavior claims must be verifiable against the docs:

- Tenant API: https://developers.cloudflare.com/tenant/how-to/manage-accounts/
- Delete endpoint: https://developers.cloudflare.com/api/resources/accounts/methods/delete/

Verified constraints: tenant-admin-only deletion (quoted verbatim from the delete endpoint
page); docs order (gateway -> access organization -> account). The docs name exactly two
resources as *not automatically deleted* — Logpush jobs ("will continue delivering logs after
account deletion") and Zero Trust Gateway configurations ("may continue resolving DNS queries
after account deletion") — while the Access organization appears as step 2 of the required
cleanup sequence rather than in that list. Keep that distinction; do not restate all three as
"not auto-deleted per the docs". Undocumented practical lore must stay labeled as lore — e.g.,
"leftover paid subscriptions are the most common cause of a failed delete in practice, not
listed in the docs' required list". Do not upgrade lore to documented fact.

## Code conventions

- Bash: `set -euo pipefail`; exact `==` name match; split one `cf` response with the
  `cf_status` / `cf_body` helpers (do not re-implement the `tail -n1 | cut -d: -f2` parsing at
  call sites), and log mutations with `cf_summary`.
- Bash credentials go to curl on stdin via `curl -K -` (see `cf_auth_config`). Never put a
  token or key in an argument list: `ps` exposes it to every local user for the whole request.
- PowerShell 7+ (uses `SkipHttpErrorCheck` and the `??` operator): `-ceq` case-sensitive match;
  `Invoke-CfApi` returns `@{ Status; Json }` — branch on `Status`, never on exceptions.
- Do not set `param()` defaults that read `$env:` values assigned by `config.ps1` — param
  defaults evaluate before the config dot-source runs. Apply the env fallback in the body after
  loading `common.ps1` (see `precheck.ps1`).
- Endpoints, headers, and credential handling live in `bash/common.sh` / `powershell/common.ps1`
  only. Each loads its config from its own directory, independent of cwd.
- List endpoints must use `cf_all_to` (bash) / `Invoke-CfApiAll` (PowerShell) — they fetch every
  page and abort on a non-200 page. Never call a list endpoint with a bare `per_page` cap;
  silent truncation is a real hazard (e.g. logpush job 51+ invisible to cleanup). The helpers
  own paging: do not embed `page`/`per_page` in the paths passed to them.
- Bash only: `cf_all_to OUTVAR METHOD PATH` assigns in the CURRENT shell (printf -v) and sets
  `CF_ALL_STATUS`. NEVER capture it in `$( )` — a command substitution is a subshell and the
  status global would be lost (tolerant branches would misread stale values). The same applies
  to any wrapper around it: a helper that sets globals must be called bare, not in `$( )`.
- Bash only: every local inside `cf_all_to` carries the `_cfa_` prefix, and OUTVAR names
  matching that prefix are rejected at runtime. Bash locals are dynamically scoped, so
  `printf -v "$outvar"` resolves inside `cf_all_to`; a caller passing the name of one of its
  locals (this happened with `resp`) silently receives an empty result, which for the logpush
  inventory meant skipping a cleanup phase with no error. Keep the prefix and the guard.
- Bash: get status and body from ONE call (`RESP=$(cf ...)`; `cf_status "$RESP"` /
  `cf_body "$RESP"`). Do not make two API calls for the same request.
- Cleanup phases assert 200/404 (404 = already gone) before the irreversible Phase 4 in both
  ports, and additionally reject a 200 carrying `success: false` — some endpoints report
  failures that way and a status-only check would let them pass.
- PowerShell: filter nulls when accumulating pages (`Where-Object { $null -ne $_ }`). An
  endpoint answering `"result": null` otherwise yields a one-element array containing `$null`,
  so an empty list reports `Count` 1 and callers iterate a phantom entry.
- Bash and PowerShell must mirror each other: precheck section numbering (1-9), dry-run plan
  text (gate + 0-4), phase order, confirmation prompts, verification steps, exit codes.
  Changing one port requires the same change in the other.
- README stays in sync with script behavior (sections, phases, prompts, permissions tables).

## Testing

- Bash syntax: `bash -n <file>` for every `.sh` touched.
- PowerShell syntax: `pwsh -NoProfile -File powershell/.syntax-check.ps1`.
- Smoke tests: fake credentials + GET-only endpoints (e.g., run `powershell/precheck.ps1` with a
  fake token — it must fail cleanly with a readable message and exit 1). Never smoke-test DELETE
  endpoints.
- Verify parity after cross-language changes: same dry-run plan text, same section list.
- Gate enforcement: `echo "LEAVE" | pwsh -NoProfile -File powershell/leave-account.ps1` must
  abort with the piped-stdin error before any mutation; the bash gate must abort without a TTY.
- Gate ordering: in a `--execute` / `-Execute` run against a throwaway account, aborting the
  account-ID prompt must leave the logpush jobs, gateway configuration and Access organization
  intact. If anything was already deleted when the prompt appeared, the ordering has regressed.
- Helper scoping (bash): `f() { local resp=""; cf_all_to resp GET "/accounts"; printf '%s' "$resp"; }`
  must fail loudly with the "unusable output variable name" error rather than returning empty.

## Publishing hygiene (run before every push)

- Customer-name leak scan: `git grep -ic <SCRUBBED_NAME> $(git rev-list --all)` → must be clean.
  Run locally with the actual scrubbed name; never commit the name itself into this repo
  (including this file).
- Secrets scan: `git grep -inE "CF_(API_TOKEN|AUTH_KEY|AUTH_EMAIL)[[:space:]]*=[[:space:]]*\"[^\"]" $(git rev-list --all)`
  → must be clean. (The optional whitespace matters: PowerShell configs are written
  `$env:CF_API_TOKEN = "..."`, which a `NAME="` pattern misses entirely.)
- Confirm gitignored: `bash/config.sh`, `powershell/config.ps1`.
- Review `git log --oneline` — no customer names in commit messages.
