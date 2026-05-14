#!/bin/bash
set -e

# Remove stale token from previous runs so the runner always waits for a fresh one
rm -f /shared/runner_token

echo "Waiting for Gitea to start..."
# Wait for port 3000 to respond
while ! curl -s http://gitea:3000/ > /dev/null; do
  echo "Gitea not responding yet..."
  sleep 5
done
echo "Gitea is up!"

# Attempting to create user. If it fails, assume it already exists.
echo "Creating admin user (if not exists)..."
su git -c "/usr/local/bin/gitea admin user create --admin --username ${GITEA_ADMIN_USER} --password '${GITEA_ADMIN_PASSWORD}' --email ${GITEA_ADMIN_EMAIL} --must-change-password=false" || echo "User creation failed (likely already exists)"

# Clean up stale runner API tokens from previous runs
echo "Cleaning up stale runner tokens from Gitea..."
STALE_TOKENS=$(curl -s "http://gitea:3000/api/v1/users/${GITEA_ADMIN_USER}/tokens?limit=50" \
  -u "${GITEA_ADMIN_USER}:${GITEA_ADMIN_PASSWORD}" | \
  grep -oE '"name":"runner-[0-9]+"' | cut -d'"' -f4)
for TNAME in $STALE_TOKENS; do
    curl -s -X DELETE "http://gitea:3000/api/v1/users/${GITEA_ADMIN_USER}/tokens/${TNAME}" \
      -u "${GITEA_ADMIN_USER}:${GITEA_ADMIN_PASSWORD}" > /dev/null
    echo "Deleted stale token: $TNAME"
done

echo "Ensuring Actions is enabled in app.ini..."
APP_INI="/data/gitea/conf/app.ini"
if ! grep -q "^\[actions\]" "$APP_INI" 2>/dev/null; then
    printf '\n[actions]\nENABLED = true\n' >> "$APP_INI"
    echo "Added [actions] section to app.ini"
fi
echo "Actions config in app.ini:"
grep -A5 "^\[actions\]" "$APP_INI" 2>/dev/null || echo "(no [actions] section found)"

echo "Generating runner token..."
MAX_RETRIES=10
COUNT=0
while [ $COUNT -lt $MAX_RETRIES ]; do
    RUNNER_REG_TOKEN=""

    # Try CLI variations (subcommand name changed across versions)
    for CMD in \
        "runners generate-registration-token" \
        "runner generate-registration-token" \
        "generate-runner-token"; do
        OUTPUT=$(su git -c "/usr/local/bin/gitea admin $CMD" 2>&1 | tr -d '[:space:]')
        echo "gitea admin $CMD => [$OUTPUT]"
        # Validate: token must be purely alphanumeric, 20+ chars
        if echo "$OUTPUT" | grep -qE '^[a-zA-Z0-9]{20,}$'; then
            RUNNER_REG_TOKEN="$OUTPUT"
            break
        fi
    done

    # Try API endpoints if CLI failed
    if [ -z "$RUNNER_REG_TOKEN" ]; then
        API_RESPONSE=$(curl -s -X POST "http://gitea:3000/api/v1/users/${GITEA_ADMIN_USER}/tokens" \
          -H "Content-Type: application/json" \
          -u "${GITEA_ADMIN_USER}:${GITEA_ADMIN_PASSWORD}" \
          -d "{\"name\": \"runner-$(date +%s)\", \"scopes\": [\"all\"]}")
        API_TOKEN=$(echo "$API_RESPONSE" | grep -o '"sha1":"[^"]*"' | cut -d'"' -f4)
        API_TOKEN_ID=$(echo "$API_RESPONSE" | grep -oE '"id":[0-9]+' | head -1 | cut -d':' -f2)

        if [ -n "$API_TOKEN" ]; then
            for REQ in \
                "GET /api/v1/admin/runners/registration-token" \
                "POST /api/v1/admin/runners/registration-token" \
                "GET /api/v1/admin/actions/runners/registration-token" \
                "POST /api/v1/admin/actions/runners/registration-token"; do
                METHOD="${REQ%% *}"
                EP="${REQ#* }"
                RESP=$(curl -s -X "$METHOD" "http://gitea:3000${EP}" -H "Authorization: token $API_TOKEN")
                echo "[$METHOD $EP] => $RESP"
                TOKEN=$(echo "$RESP" | grep -o '"token":"[^"]*"' | cut -d'"' -f4)
                if [ -n "$TOKEN" ] && [ "$TOKEN" != "null" ]; then
                    RUNNER_REG_TOKEN="$TOKEN"
                    break
                fi
            done
            # Delete the temporary API token after use
            if [ -n "$API_TOKEN_ID" ]; then
                curl -s -X DELETE "http://gitea:3000/api/v1/users/${GITEA_ADMIN_USER}/tokens/${API_TOKEN_ID}" \
                  -u "${GITEA_ADMIN_USER}:${GITEA_ADMIN_PASSWORD}" > /dev/null
                echo "Deleted temporary API token (id: $API_TOKEN_ID)"
            fi
        fi
    fi

    if [ -n "$RUNNER_REG_TOKEN" ]; then
        echo "$RUNNER_REG_TOKEN" > /shared/runner_token
        chmod 644 /shared/runner_token
        echo "Runner Registration Token saved: $RUNNER_REG_TOKEN"
        exit 0
    fi

    echo "Failed to get token, retrying in 5s... ($COUNT/$MAX_RETRIES)"
    sleep 5
    COUNT=$((COUNT+1))
done

echo "Failed to generate runner token after retries."
exit 1
