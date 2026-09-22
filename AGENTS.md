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
   or non-`[Environment]::UserInteractive`.
3. **Exact-name matching only.** Account lookups use `==` (bash) / `-ceq` (PowerShell) against the
   full name. Never weaken to partial, prefix, or fuzzy matching — lookalike production account
   names are the main hazard this repo guards against.
4. **Safety patterns must survive every edit:** dry-run default with explicit `--execute` /
   `-Execute` opt-in, Phase 0 subscription gate (abort if active subs visible), cleanup phases
   (1-3) asserting 200/404 before the irreversible delete, verification step after every
   mutation, read-only precheck that inspects all pre-deletion resources.
5. **No secrets, no real customer or account names in committed files.** This repo is public. A
   real customer name was scrubbed before publishing — do not reintroduce one. `bash/config.sh`
   and `powershell/config.ps1` are gitignored; keep credentials in them, never in scripts or
   chat history.

## Doc-accuracy rule

API behavior claims must be verifiable against the docs:

- Tenant API: https://developers.cloudflare.com/tenant/how-to/manage-accounts/
- Delete endpoint: https://developers.cloudflare.com/api/resources/accounts/methods/delete/

Verified constraints: tenant-admin-only deletion; manual pre-deletes required by the docs
(Logpush jobs, Zero Trust gateway configuration, Access organization); docs order
(gateway -> access organization -> account). Undocumented practical lore must stay labeled as
lore — e.g., "leftover paid subscriptions are the most common cause of a failed delete in
practice, not listed in the docs' required list". Do not upgrade lore to documented fact.

## Code conventions

- Bash: `set -euo pipefail`; exact `==` name match; HTTP status via `cf ... | tail -n1 | cut -d: -f2`.
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
  status global would be lost (tolerant branches would misread stale values).
- Bash: get status and body from ONE call (`RESP=$(cf ...)`; parse tail for status, head for
  body). Do not make two API calls for the same request.
- Cleanup phases assert 200/404 (404 = already gone) before the irreversible Phase 4 in both
  ports.
- Bash and PowerShell must mirror each other: precheck section numbering (1-9), dry-run plan
  text (0-4), phase order, confirmation prompts, verification steps. Changing one port requires
  the same change in the other.
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

## Publishing hygiene (run before every push)

- Customer-name leak scan: `git grep -ic <SCRUBBED_NAME> $(git rev-list --all)` → must be clean.
  Run locally with the actual scrubbed name; never commit the name itself into this repo
  (including this file).
- Secrets scan: `git grep -inE "CF_API_TOKEN=\"[^\"]|CF_AUTH_KEY=\"[^\"]" $(git rev-list --all)` → must
  be clean.
- Confirm gitignored: `bash/config.sh`, `powershell/config.ps1`.
- Review `git log --oneline` — no customer names in commit messages.
