# Copy this file to config.sh and fill in your credentials.
# config.sh is loaded by every script in this project.
# NEVER commit config.sh (add it to .gitignore).

# Preferred auth: a Cloudflare API token (dashboard: My Profile > API Tokens).
# For the tenant-level account deletion flow, the docs use the Global API Key;
# an API token works if it belongs to the tenant admin user.
export CF_API_TOKEN=""

# Alternative auth: Global API Key pair (My Profile > API Tokens > Global API Key).
# Leave blank if using CF_API_TOKEN.
export CF_AUTH_EMAIL=""
export CF_AUTH_KEY=""

# Exact account name to locate and act on. Matched EXACTLY (==), not partially.
# Tip: name accounts clearly so this can never accidentally match production,
# e.g. "Example Corp - stale account (safe to delete)".
export TARGET_ACCOUNT_NAME="Example Corp - stale account (safe to delete)"
