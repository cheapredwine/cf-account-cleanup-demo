# Copy this file to config.ps1 and fill in your credentials.
# config.ps1 is loaded by every PowerShell script in this project.
# NEVER commit config.ps1 (add it to .gitignore).

# Preferred auth: a Cloudflare API token (dashboard: My Profile > API Tokens).
# For the tenant-level account deletion flow, the docs use the Global API Key;
# an API token works if it belongs to the tenant admin user.
$env:CF_API_TOKEN = ""

# Alternative auth: Global API Key pair (My Profile > API Tokens > Global API Key).
# Leave blank if using CF_API_TOKEN.
$env:CF_AUTH_EMAIL = ""
$env:CF_AUTH_KEY = ""

# Exact account name to locate and act on. Matched EXACTLY (-ceq), not partially.
# Tip: name accounts clearly so this can never accidentally match production,
# e.g. "Example Corp - stale account (safe to delete)".
$env:TARGET_ACCOUNT_NAME = "Example Corp - stale account (safe to delete)"
