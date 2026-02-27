#!/bin/bash
set -e

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

echo "Generating runner token..."
MAX_RETRIES=10
COUNT=0
while [ $COUNT -lt $MAX_RETRIES ]; do
    # 1. Create API token
    API_TOKEN_NAME="runner-setup-$(date +%s)"
    API_TOKEN_RESPONSE=$(curl -s -X POST "http://gitea:3000/api/v1/users/${GITEA_ADMIN_USER}/tokens" \
      -H "Content-Type: application/json" \
      -u "${GITEA_ADMIN_USER}:${GITEA_ADMIN_PASSWORD}" \
      -d "{\"name\": \"$API_TOKEN_NAME\", \"scopes\": [\"all\"]}")

    echo "API Response for token creation: $API_TOKEN_RESPONSE"

    # Extract sha1 using python3 if exists, or simple grep/cut
    # Previous grep failed, trying cleaner sed
    API_TOKEN=$(echo "$API_TOKEN_RESPONSE" | grep -o "\"sha1\":\"[^\"]*\"" | cut -d'"' -f4)

    if [ -n "$API_TOKEN" ]; then
        echo "API Token created: $API_TOKEN"
        
        # 2. Obtain registration token
        REG_TOKEN_RESPONSE=$(curl -s -X GET "http://gitea:3000/api/v1/admin/runners/registration-token" \
          -H "Authorization: token $API_TOKEN")
        
        echo "Reg Token Response: $REG_TOKEN_RESPONSE"
        
        RUNNER_REG_TOKEN=$(echo "$REG_TOKEN_RESPONSE" | grep -o "\"token\":\"[^\"]*\"" | cut -d'"' -f4)
        
        if [ -n "$RUNNER_REG_TOKEN" ] && [ "$RUNNER_REG_TOKEN" != "null" ]; then
            echo "$RUNNER_REG_TOKEN" > /shared/runner_token
            chmod 644 /shared/runner_token
            echo "Runner Registration Token generated: $RUNNER_REG_TOKEN"
            exit 0
        fi
    fi
    
    echo "Failed to get token, retrying in 5s... ($COUNT/$MAX_RETRIES)"
    sleep 5
    COUNT=$((COUNT+1))
done

echo "Failed to generate runner token after retries."
exit 1
