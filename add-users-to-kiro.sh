
#!/usr/bin/env bash

set -uo pipefail

# ============================================================
# Configuration
# ============================================================
AWS_REGION="${AWS_REGION:-ap-southeast-5}"
IDENTITY_STORE_ID="${IDENTITY_STORE_ID:-}"
GROUP_NAME="kiro-users"
INPUT_CSV="${1:-users.csv}"
RESULTS_CSV="results.csv"

# ============================================================
# Validate configuration and input
# ============================================================
if [[ -z "$IDENTITY_STORE_ID" ]]; then
    echo "ERROR: IDENTITY_STORE_ID is not set."
    echo 'Run: export IDENTITY_STORE_ID="d-your-actual-id"'
    exit 1
fi

if [[ ! -f "$INPUT_CSV" ]]; then
    echo "ERROR: Input CSV not found: $INPUT_CSV"
    exit 1
fi

if ! command -v aws >/dev/null 2>&1; then
    echo "ERROR: AWS CLI is not installed."
    exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "ERROR: Python 3 is required to read the CSV."
    exit 1
fi

if ! aws sts get-caller-identity \
    --region "$AWS_REGION" >/dev/null 2>&1; then
    echo "ERROR: AWS credentials are invalid or unavailable."
    echo "Check your CloudShell session and AWS region."
    exit 1
fi

echo "Region: $AWS_REGION"
echo "Identity Store: $IDENTITY_STORE_ID"
echo "Target group: $GROUP_NAME"
echo "Input: $INPUT_CSV"
echo

# ============================================================
# Get the existing group ID
# ============================================================
echo "Looking up group: $GROUP_NAME"

GROUP_LOOKUP=$(aws identitystore get-group-id \
    --identity-store-id "$IDENTITY_STORE_ID" \
    --alternate-identifier \
    "{\"UniqueAttribute\":{\"AttributePath\":\"displayName\",\"AttributeValue\":\"$GROUP_NAME\"}}" \
    --region "$AWS_REGION" \
    --query 'GroupId' \
    --output text 2>&1)
GROUP_STATUS=$?

if [[ $GROUP_STATUS -ne 0 || -z "$GROUP_LOOKUP" || "$GROUP_LOOKUP" == "None" ]]; then
    echo "ERROR: Could not find group '$GROUP_NAME'."
    echo "$GROUP_LOOKUP"
    exit 1
fi

GROUP_ID="$GROUP_LOOKUP"
echo "Group ID: $GROUP_ID"
echo

# ============================================================
# Prepare results CSV
# ============================================================
printf '"Email","UserId","Result"\n' > "$RESULTS_CSV"

# ============================================================
# Process each user from the input CSV
# Uses Python's CSV reader to handle quoted CSV fields.
# ============================================================
while IFS=$'\t' read -r email first_name last_name; do

    # Skip empty rows
    [[ -z "$email" ]] && continue

    echo "Processing $email"

    # --------------------------------------------------------
    # Create the user directly; no existence lookup is done.
    # --------------------------------------------------------
    CREATE_OUTPUT=$(aws identitystore create-user \
        --identity-store-id "$IDENTITY_STORE_ID" \
        --user-name "$email" \
        --display-name "$first_name $last_name" \
        --name "GivenName=$first_name,FamilyName=$last_name" \
        --emails "Value=$email,Type=Work,Primary=true" \
        --region "$AWS_REGION" \
        --query 'UserId' \
        --output text 2>&1)
    CREATE_STATUS=$?

    if [[ $CREATE_STATUS -ne 0 || -z "$CREATE_OUTPUT" || "$CREATE_OUTPUT" == "None" ]]; then
        echo "ERROR: Could not create $email"
        echo "$CREATE_OUTPUT"

        printf '"%s","","%s"\n' \
            "$email" "Create failed" >> "$RESULTS_CSV"

        echo
        continue
    fi

    USER_ID="$CREATE_OUTPUT"
    echo "Created user: $USER_ID"

    # --------------------------------------------------------
    # Add the newly created user to kiro-users.
    # --------------------------------------------------------
    MEMBERSHIP_OUTPUT=$(aws identitystore create-group-membership \
        --identity-store-id "$IDENTITY_STORE_ID" \
        --group-id "$GROUP_ID" \
        --member-id "UserId=$USER_ID" \
        --region "$AWS_REGION" 2>&1)
    MEMBERSHIP_STATUS=$?

    if [[ $MEMBERSHIP_STATUS -eq 0 ]]; then
        echo "SUCCESS: Created and added $email to $GROUP_NAME"

        printf '"%s","%s","%s"\n' \
            "$email" "$USER_ID" "Created and added" >> "$RESULTS_CSV"
    else
        echo "ERROR: User created, but group membership failed."
        echo "$MEMBERSHIP_OUTPUT"

        printf '"%s","%s","%s"\n' \
            "$email" "$USER_ID" "Created; group add failed" >> "$RESULTS_CSV"
    fi

    echo

done < <(python3 - "$INPUT_CSV" <<'PY'
import csv
import sys

path = sys.argv[1]

with open(path, "r", encoding="utf-8-sig", newline="") as f:
    reader = csv.DictReader(f)

    required = {"Email", "FirstName", "LastName"}
    if not reader.fieldnames or not required.issubset(set(reader.fieldnames)):
        print(
            "ERROR: CSV headers must be Email,FirstName,LastName",
            file=sys.stderr,
        )
        sys.exit(1)

    for row in reader:
        email = (row.get("Email") or "").strip()
        first_name = (row.get("FirstName") or "").strip()
        last_name = (row.get("LastName") or "").strip()

        if not email:
            continue

        if not first_name or not last_name:
            print(
                f"WARNING: Skipping {email}: first or last name is missing.",
                file=sys.stderr,
            )
            continue

        # Tab-separated fields for the Bash loop.
        # Names containing tabs are not supported by this simple interface.
        fields = (email, first_name, last_name)
        if any("\t" in value or "\n" in value for value in fields):
            print(
                f"WARNING: Skipping {email}: tab/newline in a field.",
                file=sys.stderr,
            )
            continue

        print("\t".join(fields))
PY
)

echo "Finished processing CSV."
echo "Results saved to: $RESULTS_CSV"
echo
cat "$RESULTS_CSV"
