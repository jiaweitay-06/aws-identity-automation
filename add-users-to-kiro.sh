#!/usr/bin/env bash

set -uo pipefail

AWS_REGION="${AWS_REGION:-ap-southeast-5}"
IDENTITY_STORE_ID="${IDENTITY_STORE_ID:-}"
GROUP_NAME="Kiro Users"
INPUT_CSV="${1:-users.csv}"
RESULTS_CSV="results.csv"

if [[ -z "$IDENTITY_STORE_ID" ]]; then
    echo 'ERROR: Set IDENTITY_STORE_ID first.'
    echo 'Example: export IDENTITY_STORE_ID="d-xxxxxxxxxx"'
    exit 1
fi

if [[ ! -f "$INPUT_CSV" ]]; then
    echo "ERROR: CSV file not found: $INPUT_CSV"
    exit 1
fi

# Find the existing group by its exact display name.
GROUP_ID=$(aws identitystore get-group-id \
    --identity-store-id "$IDENTITY_STORE_ID" \
    --alternate-identifier \
    "{\"UniqueAttribute\":{\"AttributePath\":\"displayName\",\"AttributeValue\":\"$GROUP_NAME\"}}" \
    --region "$AWS_REGION" \
    --query GroupId \
    --output text) || {
        echo "ERROR: Could not find group '$GROUP_NAME'."
        exit 1
    }

echo "Target group: $GROUP_NAME ($GROUP_ID)"
echo '"Email","UserId","Result"' > "$RESULTS_CSV"

# Python reads CSV correctly, including quoted fields.
while IFS=$'\t' read -r email first_name last_name; do
    [[ -z "$email" ]] && continue

    echo
    echo "Processing $email"

    # Create user directly. No ListUsers lookup.
    if USER_ID=$(aws identitystore create-user \
        --identity-store-id "$IDENTITY_STORE_ID" \
        --user-name "$email" \
        --display-name "$first_name $last_name" \
        --name "GivenName=$first_name,FamilyName=$last_name" \
        --emails "Value=$email,Type=work,Primary=true" \
        --region "$AWS_REGION" \
        --query UserId \
        --output text 2>&1); then

        echo "Created user: $USER_ID"
    else
        echo "ERROR creating $email: $USER_ID"
        printf '"%s","","Create failed"\n' "$email" >> "$RESULTS_CSV"
        continue
    fi

    # Add the newly created user to the group.
    if MEMBERSHIP_OUTPUT=$(aws identitystore create-group-membership \
        --identity-store-id "$IDENTITY_STORE_ID" \
        --group-id "$GROUP_ID" \
        --member-id "UserId=$USER_ID" \
        --region "$AWS_REGION" 2>&1); then

        echo "SUCCESS: $email added to $GROUP_NAME"
        printf '"%s","%s","Created and added"\n' \
            "$email" "$USER_ID" >> "$RESULTS_CSV"
    else
        echo "ERROR adding $email to group: $MEMBERSHIP_OUTPUT"
        printf '"%s","%s","Created; group add failed"\n' \
            "$email" "$USER_ID" >> "$RESULTS_CSV"
    fi

done < <(python3 - "$INPUT_CSV" <<'PY'
import csv
import sys

with open(sys.argv[1], encoding="utf-8-sig", newline="") as f:
    reader = csv.DictReader(f)
    required = {"Email", "FirstName", "LastName"}

    if not reader.fieldnames or not required.issubset(reader.fieldnames):
        sys.exit("ERROR: CSV headers must be Email,FirstName,LastName")

    for row in reader:
        email = (row.get("Email") or "").strip()
        first = (row.get("FirstName") or "").strip()
        last = (row.get("LastName") or "").strip()

        if not email:
            continue
        if not first or not last:
            print(f"WARNING: Skipping {email}: missing name.", file=sys.stderr)
            continue
        if any("\t" in x or "\n" in x for x in (email, first, last)):
            print(f"WARNING: Skipping {email}: invalid field.", file=sys.stderr)
            continue

        print(f"{email}\t{first}\t{last}")
PY
)

echo
echo "Finished. Results saved to ./$RESULTS_CSV"
cat "$RESULTS_CSV"
