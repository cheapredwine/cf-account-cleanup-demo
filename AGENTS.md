# AGENTS.md

Guidance for AI coding agents working in this repository.

## What this repo is

Public demo code: safe, auditable scripts for removing a Cloudflare account via
the API, in two languages that must stay in behavioral parity.

- Bash: `precheck.sh`, `leave-account.sh`, `delete-account.sh` (+ `common.sh`, `config.example.sh`)
- PowerShell 7+: `precheck.ps1`, `leave-account.ps1`, `delete-account.ps1` (+ `common.ps1`, `config.example.ps1`)

Customer-facing doc: `README.md`. Dev tool: `.syntax-check.ps1` (PowerShell parse check).

## Critical rules

1. **Never execute destructive API calls.** `delete-account.sh --execute` /
   `delete-account.ps1 -Execute` permanently delete an account. Only a human runs them, only
   after reviewing precheck output, and only against a throwaway account. Agents test with dry
   runs (the default) and fake credentials only.
2. **Typed confirmations are load-bearing.** The `LEAVE` gate and the full 32-character account-ID
   gate must never be weakened, automated, or bypassed (no default answers, no piped input).
3. **Exact-name matching only.** Account lookups use `==` (bash) / `-ceq` (PowerShell) against the
   full name. Never weaken to partial, prefix, or fuzzy matching — lookalike production account
   names are the main hazard this repo guards against.
4. **Safety patterns must survive every edit:** dry-run default with explicit `--execute` /
   `-Execute` opt-in, Phase 0 subscription gate (abort if active subs visible), verification step
   after every mutation, read-only precheck that inspects all pre-deletion resources.
5. **No secrets, no real customer or account names in committed files.** This repo is public. A
   real customer name was scrubbed before publishing — do not reintroduce one. `config.sh` and
   `config.ps1` are gitignored; keep credentials in them, never in scripts or chat history.

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
- Endpoints, headers, and credential handling live in `common.sh` / `common.ps1` only.
- Bash and PowerShell must mirror each other: precheck section numbering (1-9), dry-run plan
  text (0-4), phase order, confirmation prompts, verification steps. Changing one port requires
  the same change in the other.
- README stays in sync with script behavior (sections, phases, prompts, permissions tables).

## Testing

- Bash syntax: `bash -n <file>` for every `.sh` touched.
- PowerShell syntax: `pwsh -NoProfile -File .syntax-check.ps1`.
- Smoke tests: fake credentials + GET-only endpoints (e.g., run `precheck.ps1` with a fake token —
  it must fail cleanly with a readable message and exit 1). Never smoke-test DELETE endpoints.
- Verify parity after cross-language changes: same dry-run plan text, same section list.

## Publishing hygiene (run before every push)

- Customer-name leak scan: `git grep -ic <SCRUBBED_NAME> $(git rev-list --all)` → must be clean.
  Run locally with the actual scrubbed name; never commit the name itself into this repo
  (including this file).
- Secrets scan: `git grep -inE "CF_API_TOKEN=\"[^\"]|CF_AUTH_KEY=\"[^\"]" $(git rev-list --all)` → must
  be clean.
- Confirm gitignored: `config.sh`, `config.ps1`.
- Review `git log --oneline` — no customer names in commit messages.
