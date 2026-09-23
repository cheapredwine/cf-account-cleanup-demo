# Cloudflare Account Removal Scripts

Demo scripts for safely removing a Cloudflare account via the API — with a read-only preflight, a dry-run-by-default deletion flow, and a typed confirmation before anything destructive runs.

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
3. **Some resources survive the account** and must be removed first (the scripts do this in `--execute` mode). The docs call out two as *not automatically deleted*:
   - **Logpush jobs** — "will continue delivering logs after account deletion"
   - **Zero Trust Gateway configuration** — "may continue resolving DNS queries after account deletion"

   The docs' cleanup sequence also deletes the **Access organization** before the account, so the scripts do all three.
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
| `precheck.sh` (read-only) | Account Settings:Read, Zone:Read, Logpush:Read, Zero Trust:Read, Memberships:Read, plus billing read for the subscriptions section |
| `leave-account.sh` | Membership:Read, Membership:Edit |
| `delete-account.sh --execute` | Account Settings:Read + Write, Zone:Read, Account Members:Read, Logpush:Read + Edit, Zero Trust:Read + Edit (Gateway and Access), billing read for the subscription gate, plus tenant-admin authority over the account |

A missing permission does **not** degrade quietly: any section or inventory the credential cannot read is reported as `UNREADABLE`, and `--execute` aborts rather than treating "cannot see" as "nothing there". Grant the permissions above or expect the run to stop.
The reads are required because the run refuses to act on an inventory it cannot fully list and verifies every cleanup phase with a follow-up read.

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

Exits `0` when every section was readable, `1` when any section was not — an unreadable section is printed as `UNREADABLE`, never as `none`.

### 2. Option A — hide the account from your dashboard

```bash
bash/leave-account.sh
# Requires typing LEAVE to confirm. The account is NOT deleted.
```

### 3. Option B — delete the account permanently

```bash
bash/delete-account.sh            # DRY RUN (default): shows the plan, changes nothing
bash/delete-account.sh --execute  # real run: complete inventory, typed confirmation, then cleanup + deletion
```

What `--execute` does, in order:
1. **Inventory completeness check** — aborts before the confirmation prompt if the Logpush or member inventory cannot be read.
2. **Typed confirmation, before any change** — prints the inventory of what will be destroyed, then requires the full account ID to be typed at an interactive terminal. Anything else aborts with nothing changed.
3. Subscription gate — lists every page, then aborts if any active subscriptions are visible (cancel via billing first) or the list cannot be read.
4. Deletes all Logpush jobs, then re-lists every page and requires none remain.
5. Deletes the Zero Trust gateway configuration, then reads it back and requires it to be gone.
6. Deletes the Access organization, then reads it back and requires it to be gone.
7. Deletes the account.
8. Verifies deletion (expects HTTP 403/404 on a follow-up GET; exits non-zero otherwise).

Steps 4–6 destroy Gateway policies and every Access app and policy in the account, which is why the confirmation comes before them rather than just before step 7. An unreadable verification read aborts before the account delete.

If the credential genuinely cannot read subscriptions and billing has been checked another way, `BILLING_VERIFIED=1 bash/delete-account.sh --execute` records that decision explicitly and continues past step 3 only.

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
- **Duplicate names abort** — account names are not unique in Cloudflare; if two accounts share the exact target name, the scripts list both IDs and refuse to guess rather than acting on the first match
- **Dry-run default** on the deletion script; `--execute` / `-Execute` is the explicit opt-in, and an unrecognised argument is an error rather than a silent dry run
- **Typed confirmation before the first mutation, interactive-only** — `LEAVE` for the reversible operation, the full account ID for the irreversible one; the ID is asked before the cleanup phases, not after them; piped/redirected stdin is rejected (bash reads `/dev/tty`, PowerShell checks `[Console]::IsInputRedirected`)
- **"Cannot see" is never "nothing there"** — an unreadable zone, logpush, gateway, Access, subscription or member listing is reported as `UNREADABLE`; unreadable Logpush or member inventory aborts before the confirmation prompt, and a 403 is never rendered as "none"
- **No pagination truncation** — all list endpoints, including subscriptions, fetch every page; a failed page aborts instead of silently capping at 50 items
- **Cleanup-phase assertions** — every pre-delete cleanup phase must return 200/404 *and* must not report `success: false` on a 200, or the run aborts before the account delete
- **Per-phase verification** — Logpush is re-listed and must be empty; Gateway and Access are read back and must be absent before account deletion
- **Post-delete verification** — the account is read back after deletion, with a non-zero exit when it remains readable
- **Credentials stay out of `ps`** — the bash port passes auth headers to curl on stdin (`curl -K -`) instead of the command line
- **Read-only preflight** shares exactly what will be destroyed, before anything runs

## Recommended customer workflow

1. Run `bash/precheck.sh` and review the zone list with stakeholders
2. Confirm which option matches the actual goal (A: hide, B: destroy)
3. For B: verify Logpush/gateway/Access cleanup completes, then delete
4. If the credential is not a tenant admin over the account: engage the Cloudflare account team for deletion

## Disclaimer

Demo code for customer education. Not an official Cloudflare product; no SLA or support. **Always test against a throwaway account first** — Option B cannot be undone.
