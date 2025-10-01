#!/usr/bin/env bash
set -euo pipefail

# MinIO + Keycloak OIDC Authentication Script
# 
# This script demonstrates how to authenticate with MinIO using Keycloak OIDC
# and obtain temporary AWS credentials via MinIO's STS (Security Token Service).
#
# Usage:
#   ./login-minio-oidc.sh                                    # Interactive mode
#   ./login-minio-oidc.sh username                           # Username provided, password prompted
#   KEYCLOAK_PASSWORD=xxx ./login-minio-oidc.sh username     # Environment variable (secure)
#   KEYCLOAK_CLIENT_SECRET=xxx ./login-minio-oidc.sh username # Client secret via env var
#
# Prerequisites:
#   - jq (JSON processor)
#   - xmllint (XML processor) - optional, sed fallback available
#   - curl
#   - aws CLI (for testing)
#
# Author: Community contribution
# License: MIT

# --- CONFIGURATION (EDIT THESE VALUES) ---
KEYCLOAK_URL="${KEYCLOAK_URL:-https://your-keycloak.example.com/auth/realms/your-realm/protocol/openid-connect/token}"
CLIENT_ID="${CLIENT_ID:-your-minio-client-id}"
CLIENT_SECRET="${KEYCLOAK_CLIENT_SECRET:-}"  # Set via environment variable for security
MINIO_STS_URL="${MINIO_STS_URL:-https://minio-api.example.com}"

# --- ARGUMENT PARSING ---
USERNAME="${1:-}"
PASSWORD="${2:-}"

# --- HELPER FUNCTIONS ---
show_usage() {
    echo "Usage: $0 [username] [password]"
    echo ""
    echo "Environment variables:"
    echo "  KEYCLOAK_URL           - Keycloak token endpoint"
    echo "  CLIENT_ID              - Keycloak client ID"
    echo "  KEYCLOAK_CLIENT_SECRET - Keycloak client secret"
    echo "  MINIO_STS_URL          - MinIO API endpoint"
    echo "  KEYCLOAK_PASSWORD      - User password (alternative to interactive input)"
    echo ""
    echo "Examples:"
    echo "  $0                                    # Interactive mode"
    echo "  $0 john.doe                          # Username provided"
    echo "  KEYCLOAK_PASSWORD=xxx $0 john.doe    # Password via env var"
    exit 1
}

decode_jwt() {
    local token=$1
    local payload=$(echo -n "$token" | cut -d. -f2)
    local fixed=$(echo -n "$payload" | tr '_-' '/+')
    local mod4=$(( ${#fixed} % 4 ))
    if [ $mod4 -gt 0 ]; then
        fixed="$fixed$(printf '=%.0s' $(seq 1 $((4 - mod4))))"
    fi
    echo -n "$fixed" | base64 -d 2>/dev/null | jq .
}

# --- VALIDATION ---
if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    show_usage
fi

# Check required tools
for tool in jq curl; do
    if ! command -v "$tool" &> /dev/null; then
        echo "❌ Required tool '$tool' is not installed"
        exit 1
    fi
done

# Validate configuration
if [[ -z "$KEYCLOAK_URL" || -z "$CLIENT_ID" || -z "$MINIO_STS_URL" ]]; then
    echo "❌ Missing required configuration. Please set environment variables:"
    echo "   KEYCLOAK_URL, CLIENT_ID, MINIO_STS_URL"
    show_usage
fi

# --- INPUT COLLECTION ---
# Get username
if [[ -z "$USERNAME" ]]; then
    read -p "Username: " USERNAME
fi

# Get password
if [[ -z "$PASSWORD" ]]; then
    # Try environment variable first
    PASSWORD="${KEYCLOAK_PASSWORD:-}"
    
    # If still no password, prompt securely
    if [[ -z "$PASSWORD" ]]; then
        read -s -p "Password: " PASSWORD
        echo  # New line after masked input
    fi
fi

# Get client secret
if [[ -z "$CLIENT_SECRET" ]]; then
    read -s -p "Client Secret: " CLIENT_SECRET
    echo  # New line after masked input
fi

# Final validation
if [[ -z "$USERNAME" || -z "$PASSWORD" || -z "$CLIENT_SECRET" ]]; then
    echo "❌ Username, password, and client secret are required"
    exit 1
fi

# --- STEP 1: AUTHENTICATE WITH KEYCLOAK ---
echo "🔑 Getting Keycloak token for $USERNAME..."
TOKEN_RESPONSE=$(curl -s -X POST \
    -d "client_id=$CLIENT_ID" \
    -d "client_secret=$CLIENT_SECRET" \
    -d "username=$USERNAME" \
    -d "password=$PASSWORD" \
    -d "grant_type=password" \
    "$KEYCLOAK_URL")

TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r .access_token)

if [[ "$TOKEN" == "null" || -z "$TOKEN" ]]; then
    echo "❌ Failed to get access token from Keycloak"
    echo "Response: $TOKEN_RESPONSE"
    exit 1
fi

echo "✅ Successfully obtained Keycloak token"

# --- STEP 2: DECODE AND DISPLAY JWT CLAIMS ---
echo "📜 JWT payload (relevant claims):"
if command -v jq &> /dev/null; then
    decode_jwt "$TOKEN" | jq '{preferred_username, policy, groups, exp}' 2>/dev/null || echo "Could not decode JWT payload"
fi

# --- STEP 3: EXCHANGE TOKEN WITH MINIO STS ---
echo "🔄 Exchanging token with MinIO STS..."
STS_XML=$(curl -s --max-time 30 -X POST "$MINIO_STS_URL" \
    -d "Action=AssumeRoleWithWebIdentity" \
    -d "Version=2011-06-15" \
    -d "DurationSeconds=3600" \
    -d "WebIdentityToken=$TOKEN")

if [[ -z "$STS_XML" ]]; then
    echo "❌ No response from MinIO STS"
    exit 1
fi

# --- STEP 4: EXTRACT CREDENTIALS FROM STS RESPONSE ---
# Try xmllint first, fall back to sed
ACCESS_KEY=$(echo "$STS_XML" | xmllint --xpath "string(//*[local-name()='AccessKeyId'])" - 2>/dev/null || \
            echo "$STS_XML" | sed -n 's/.*<AccessKeyId>\(.*\)<\/AccessKeyId>.*/\1/p')
SECRET_KEY=$(echo "$STS_XML" | xmllint --xpath "string(//*[local-name()='SecretAccessKey'])" - 2>/dev/null || \
            echo "$STS_XML" | sed -n 's/.*<SecretAccessKey>\(.*\)<\/SecretAccessKey>.*/\1/p')
SESSION_TOKEN=$(echo "$STS_XML" | xmllint --xpath "string(//*[local-name()='SessionToken'])" - 2>/dev/null || \
               echo "$STS_XML" | sed -n 's/.*<SessionToken>\(.*\)<\/SessionToken>.*/\1/p')

if [[ -z "$ACCESS_KEY" ]]; then
    echo "❌ Failed to extract credentials from STS response"
    echo "STS Response: $STS_XML"
    exit 1
fi

echo "✅ Successfully obtained temporary AWS credentials (valid 1 hour)"

# --- STEP 5: CONFIGURE AWS CLI ENVIRONMENT ---
export AWS_ACCESS_KEY_ID="$ACCESS_KEY"
export AWS_SECRET_ACCESS_KEY="$SECRET_KEY"
export AWS_SESSION_TOKEN="$SESSION_TOKEN"

echo ""
echo "🔗 AWS credentials configured. Testing access..."
if command -v aws &> /dev/null; then
    aws --endpoint-url "$MINIO_STS_URL" s3 ls
else
    echo "⚠️  AWS CLI not found. Install it to test S3 access."
fi

echo ""
echo "🎉 Authentication complete! You can now use AWS CLI or SDK with MinIO:"
echo "   export AWS_ACCESS_KEY_ID=\"$ACCESS_KEY\""
echo "   export AWS_SECRET_ACCESS_KEY=\"$SECRET_KEY\""
echo "   export AWS_SESSION_TOKEN=\"$SESSION_TOKEN\""
echo ""
echo "   aws --endpoint-url $MINIO_STS_URL s3 ls"
echo ""
echo "💡 Credentials expire in 1 hour. Re-run this script to refresh."
