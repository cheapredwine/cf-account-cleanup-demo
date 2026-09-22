# Cloudflare Account Removal Scripts

Demo scripts for safely removing a Cloudflare account via the API — with a read-only preflight, a dry-run-by-default deletion flow, and typed confirmations before anything destructive runs.

> **Read this first.** There are two very different operations, and choosing the wrong one is either wasted work or permanent data loss. Start with `bash/precheck.sh` and review its output before running anything else.

---

## The two operations

| | Option A — Hide from dashboard | Option B — Delete the account |
|---|---|---|
| **API call** | `DELETE /memberships/{membership_id}` | `DELETE /accounts/{account_id}` |
| **Effect** | Removes the account from *your user's* dashboard view only. Account, zones, and data remain for other members/owner. | Permanently destroys the account, its zones, and most resources under it. |
| **Reversible** | Yes — the account owner can re-invite your user at any time. | No. |
| **Use when** | The goal is "stop seeing it in the dashboard". | The goal is "remove the account entirely". |

Most "we want this account gone" requests are actually Option A. Confirm intent before proceeding to Option B.

## Critical constraints on Option B

1. **Tenant admins only.** Per the [Tenant API docs](https://developers.cloudflare.com/tenant/how-to/manage-accounts/), `DELETE /accounts/{account_id}` is *"only available for tenant admins at this time."* It works for accounts owned or created by the tenant behind the credential. A normal customer account typically **cannot self-delete via API** — that is handled by the Cloudflare account team/support.
2. **Deletion is permanent.** Zones under the account are destroyed and cannot be recovered.
3. **These are NOT auto-deleted** and must be removed first (the scripts do this in `--execute` mode):
   - Logpush jobs — if left behind, log delivery can continue after deletion
   - Zero Trust gateway configuration
   - Access organization
4. **Order of operations** (per docs): gateway configuration → Access organization → account. Subscriptions are not listed as a required manual pre-delete in the docs, but leftover paid subscriptions are the most common cause of a failed delete in practice — the `--execute` flow aborts if any are visible; cancel those via billing first.

---

## Setup

```bash
# 1. Install jq (required)
brew install jq          # macOS
# apt install jq         # Debian/Ubuntu

# 2. Create your config
cd bash
cp config.example.sh config.sh

# 3. Fill in credentials in config.sh:
#    - CF_API_TOKEN (preferred), or
#    - CF_AUTH_EMAIL + CF_AUTH_KEY (Global API Key)
#    - TARGET_ACCOUNT_NAME — the exact account name to act on
```

**API token permissions:**

| Script | Permissions needed |
|---|---|
| `precheck.sh` (read-only) | Account Settings:Read, Zone:Read, Logpush:Read, Zero Trust:Read |
| `leave-account.sh` | Membership:Read, Membership:Edit |
| `delete-account.sh --execute` | Account Settings:Write, Logpush:Edit, Zero Trust:Edit, plus tenant-admin authority over the account |

The tenant-level deletion flow per the docs uses the **Global API Key**; an API token works if it belongs to the tenant admin user.

**Windows / PowerShell 7+** (`pwsh`): in `powershell/`, copy `config.example.ps1` to `config.ps1` and fill in the same values. The `.ps1` scripts mirror the `.sh` scripts exactly — same endpoints, same confirmation gates, same dry-run plan. No jq needed.

---

## Usage

### 1. Preflight (read-only, zero mutations)

```bash
bash/precheck.sh                # uses TARGET_ACCOUNT_NAME from bash/config.sh
bash/precheck.sh "Other name"   # or pass the exact account name as arg 1
```

Sections:
1. Locate the account by **exact name** match → prints the account ID
2. Account details (id, name, created date)
3. Zones under the account — **these are destroyed with it**
4. Subscriptions/entitlements — cancel before deletion; active subs are the most common cause of a failed delete
5. Logpush jobs — must be deleted manually before account deletion
6. Zero Trust gateway configuration — delete manually before deletion
7. Access organization — delete manually before deletion
8. Members with access — confirm nobody else relies on this account
9. Your membership entry for this account

### 2. Option A — hide the account from your dashboard

```bash
bash/leave-account.sh
# Requires typing LEAVE to confirm. The account is NOT deleted.
```

### 3. Option B — delete the account permanently

```bash
bash/delete-account.sh            # DRY RUN (default): shows the plan, changes nothing
bash/delete-account.sh --execute  # real run: cleanup phases + deletion,
                                  # still requires typing the full 32-char account ID
```

What `--execute` does, in order:
1. Subscription gate — aborts if any active subscriptions are visible (cancel via billing first)
2. Deletes all Logpush jobs found on the account
3. Deletes the Zero Trust gateway configuration
4. Deletes the Access organization
5. Deletes the account — after a typed confirmation of the full account ID
6. Verifies deletion (expects HTTP 403/404 on a follow-up GET)

### PowerShell equivalent (Windows / `pwsh` 7+)

```powershell
powershell/precheck.ps1                            # read-only preflight (same 9 sections)
powershell/precheck.ps1 -TargetAccountName "Other" # exact account name as parameter
powershell/leave-account.ps1                       # Option A (typed LEAVE gate)
powershell/delete-account.ps1                      # Option B dry run (default)
powershell/delete-account.ps1 -Execute             # real run, typed account ID gate
```

---

## Safety features

- **Exact-name matching** (`==` / `-ceq`, not partial) — no fuzzy matching against lookalike production account names
- **Dry-run default** on the deletion script; `--execute` / `-Execute` is the explicit opt-in
- **Typed confirmation gates, interactive-only** — `LEAVE` for the reversible operation, the full account ID for the irreversible one; piped/redirected stdin is rejected (bash reads `/dev/tty`, PowerShell checks `[Console]::IsInputRedirected`)
- **No pagination truncation** — all list endpoints fetch every page; a failed page aborts instead of silently capping at 50 items
- **Cleanup-phase assertions** — every pre-delete cleanup phase must return 200/404 or the run aborts before the account delete
- **Verification steps** after every mutation
- **Read-only preflight** shares exactly what will be destroyed, before anything runs

## Recommended customer workflow

1. Run `bash/precheck.sh` and review the zone list with stakeholders
2. Confirm which option matches the actual goal (A: hide, B: destroy)
3. For B: verify Logpush/gateway/Access cleanup completes, then delete
4. If the credential is not a tenant admin over the account: engage the Cloudflare account team for deletion

## Disclaimer

Demo code for customer education. Not an official Cloudflare product; no SLA or support. **Always test against a throwaway account first** — Option B cannot be undone.
