
#!/usr/bin/env bash

set -uo pipefail

# ============================================================
# Configuration
# ============================================================
AWS_REGION="${AWS_REGION:-ap-southeast-5}"
IDENTITY_STORE_ID="${IDENTITY_STORE_ID:-}"

# ============================================================
# Helper functions
# ============================================================
pause() {
    read -r -p "Press Enter to continue..."
}

json_value() {
    python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"
}

confirm() {
    local answer
    read -r -p "$1 [y/N]: " answer
    [[ "$answer" =~ ^[Yy]$ ]]
}

# ============================================================
# Prerequisites
# ============================================================
if [[ -z "$IDENTITY_STORE_ID" ]]; then
    echo "ERROR: IDENTITY_STORE_ID is not set."
    echo 'Run: export IDENTITY_STORE_ID="d-your-actual-id"'
    exit 1
fi

if ! command -v aws >/dev/null 2>&1; then
    echo "ERROR: AWS CLI is not installed."
    exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "ERROR: Python 3 is required."
    exit 1
fi

if ! aws sts get-caller-identity \
    --region "$AWS_REGION" >/dev/null 2>&1; then
    echo "ERROR: AWS credentials unavailable."
    exit 1
fi

echo "========================================"
echo " IAM Identity Center - Add Users"
echo "========================================"
echo "Region: $AWS_REGION"
echo "Identity Store: $IDENTITY_STORE_ID"
echo

# ============================================================
# Collect users interactively
# ============================================================
while true; do
    read -r -p "How many users do you want to add? " USER_COUNT

    if [[ "$USER_COUNT" =~ ^[1-9][0-9]*$ ]] &&
       (( USER_COUNT <= 500 )); then
        break
    fi

    echo "Enter a whole number between 1 and 500."
done

declare -a USER_EMAILS=()
declare -a USER_FIRST_NAMES=()
declare -a USER_LAST_NAMES=()
declare -a USER_IDS=()
declare -a USER_RESULTS=()

echo
echo "Enter the details for each user."
echo

for ((i = 1; i <= USER_COUNT; i++)); do
    echo "--- User $i of $USER_COUNT ---"

    while true; do
        read -r -p "Email: " email
        email="${email#"${email%%[![:space:]]*}"}"
        email="${email%"${email##*[![:space:]]}"}"

        if [[ -n "$email" && "$email" == *@* ]]; then
            break
        fi

        echo "Please enter a valid-looking email address."
    done

    while true; do
        read -r -p "First name: " first_name
        if [[ -n "${first_name//[[:space:]]/}" ]]; then
            break
        fi
        echo "First name cannot be empty."
    done

    while true; do
        read -r -p "Last name: " last_name
        if [[ -n "${last_name//[[:space:]]/}" ]]; then
            break
        fi
        echo "Last name cannot be empty."
    done

    USER_EMAILS+=("$email")
    USER_FIRST_NAMES+=("$first_name")
    USER_LAST_NAMES+=("$last_name")

    echo
done

# ============================================================
# Optional group assignment
# ============================================================
ASSIGN_GROUP="no"
GROUP_ID=""
GROUP_NAME=""

if confirm "Would you like to add these users to a group?"; then
    ASSIGN_GROUP="yes"

    while true; do
        read -r -p "Enter the group name: " GROUP_NAME
        if [[ -n "${GROUP_NAME//[[:space:]]/}" ]]; then
            break
        fi
        echo "Group name cannot be empty."
    done

    # Find an existing group by exact display name.
    ALT_IDENTIFIER=$(python3 -c '
import json,sys
print(json.dumps({
    "UniqueAttribute": {
        "AttributePath": "displayName",
        "AttributeValue": sys.argv[1]
    }
}))
' "$GROUP_NAME")

    if GROUP_ID=$(aws identitystore get-group-id \
        --identity-store-id "$IDENTITY_STORE_ID" \
        --alternate-identifier "$ALT_IDENTIFIER" \
        --region "$AWS_REGION" \
        --query 'GroupId' \
        --output text 2>/dev/null) &&
       [[ -n "$GROUP_ID" && "$GROUP_ID" != "None" ]]; then

        echo "Found existing group: $GROUP_NAME ($GROUP_ID)"

    else
        echo "Group '$GROUP_NAME' was not found."

        if ! confirm "Create this group?"; then
            echo "Group creation declined. Users will be created without group assignment."
            ASSIGN_GROUP="no"
        else
            GROUP_INPUT=$(python3 -c '
import json,sys
print(json.dumps({
    "IdentityStoreId": sys.argv[1],
    "DisplayName": sys.argv[2]
}))
' "$IDENTITY_STORE_ID" "$GROUP_NAME")

            if GROUP_ID=$(aws identitystore create-group \
                --cli-input-json "$GROUP_INPUT" \
                --region "$AWS_REGION" \
                --query 'GroupId' \
                --output text 2>&1); then

                echo "Created group: $GROUP_NAME ($GROUP_ID)"
            else
                echo "ERROR: Could not create group."
                echo "$GROUP_ID"
                echo "Users can still be created without group assignment."

                if confirm "Continue creating users without a group?"; then
                    ASSIGN_GROUP="no"
                    GROUP_ID=""
                else
                    exit 1
                fi
            fi
        fi
    fi
fi

# ============================================================
# Review before making changes
# ============================================================
echo
echo "========================================"
echo " Review"
echo "========================================"
echo "Users to create: $USER_COUNT"

for ((i = 0; i < USER_COUNT; i++)); do
    printf '%d. %s (%s %s)\n' \
        "$((i + 1))" \
        "${USER_EMAILS[$i]}" \
        "${USER_FIRST_NAMES[$i]}" \
        "${USER_LAST_NAMES[$i]}"
done

if [[ "$ASSIGN_GROUP" == "yes" ]]; then
    echo "Target group: $GROUP_NAME"
else
    echo "Group assignment: None"
fi

echo
if ! confirm "Proceed with these changes?"; then
    echo "Cancelled. No users were created."
    exit 0
fi

# ============================================================
# Create users and optionally add them to the group
# ============================================================
CREATED=0
FAILED=0
ADDED=0
GROUP_FAILED=0

echo

for ((i = 0; i < USER_COUNT; i++)); do
    email="${USER_EMAILS[$i]}"
    first_name="${USER_FIRST_NAMES[$i]}"
    last_name="${USER_LAST_NAMES[$i]}"

    echo "Processing $email..."

    # Build JSON safely so spaces and apostrophes in names work.
    USER_INPUT=$(python3 -c '
import json,sys
print(json.dumps({
    "IdentityStoreId": sys.argv[1],
    "UserName": sys.argv[2],
    "DisplayName": sys.argv[3] + " " + sys.argv[4],
    "Name": {
        "GivenName": sys.argv[3],
        "FamilyName": sys.argv[4]
    },
    "Emails": [{
        "Value": sys.argv[2],
        "Type": "work",
        "Primary": True
    }]
}))
' "$IDENTITY_STORE_ID" "$email" "$first_name" "$last_name")

    if USER_ID=$(aws identitystore create-user \
        --cli-input-json "$USER_INPUT" \
        --region "$AWS_REGION" \
        --query 'UserId' \
        --output text 2>&1); then

        if [[ -z "$USER_ID" || "$USER_ID" == "None" ]]; then
            echo "ERROR: AWS returned no UserId for $email."
            USER_RESULTS+=("$email | Creation failed: no UserId")
            ((FAILED+=1))
            echo
            continue
        fi

        echo "Created user: $USER_ID"
        ((CREATED+=1))
        USER_IDS+=("$USER_ID")

        if [[ "$ASSIGN_GROUP" == "yes" ]]; then
            MEMBERSHIP_INPUT=$(python3 -c '
import json,sys
print(json.dumps({
    "IdentityStoreId": sys.argv[1],
    "GroupId": sys.argv[2],
    "MemberId": {"UserId": sys.argv[3]}
}))
' "$IDENTITY_STORE_ID" "$GROUP_ID" "$USER_ID")

            if MEMBERSHIP_OUTPUT=$(aws identitystore create-group-membership \
                --cli-input-json "$MEMBERSHIP_INPUT" \
                --region "$AWS_REGION" 2>&1); then

                echo "Added to group: $GROUP_NAME"
                USER_RESULTS+=("$email | Created and added to $GROUP_NAME")
                ((ADDED+=1))
            else
                echo "ERROR adding to group: $MEMBERSHIP_OUTPUT"
                USER_RESULTS+=("$email | Created; group assignment failed")
                ((GROUP_FAILED+=1))
            fi
        else
            USER_RESULTS+=("$email | Created; no group assignment")
        fi

    else
        echo "ERROR creating $email:"
        echo "$USER_ID"
        USER_RESULTS+=("$email | Creation failed")
        ((FAILED+=1))
    fi

    echo
done

# ============================================================
# Summary
# ============================================================
echo
echo "========================================"
echo " Final Summary"
echo "========================================"
echo "Users requested: $USER_COUNT"
echo "Users created: $CREATED"
echo "Creation failures: $FAILED"

if [[ "$ASSIGN_GROUP" == "yes" ]]; then
    echo "Users added to group: $ADDED"
    echo "Group assignment failures: $GROUP_FAILED"
fi

echo
echo "Individual results:"
for result in "${USER_RESULTS[@]}"; do
    echo "- $result"
done

echo
echo "Finished."
SCRIPT
