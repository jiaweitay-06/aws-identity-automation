
#!/usr/bin/env bash

set -uo pipefail

AWS_REGION="${AWS_REGION:-ap-southeast-5}"
IDENTITY_STORE_ID="${IDENTITY_STORE_ID:-}"
CSV_FILE="${1:-users.csv}"
RESULTS_FILE="results.csv"

# Temporary files
TEMP_USERS="$(mktemp)"
TEMP_RESULTS="$(mktemp)"
TEMP_ERROR="$(mktemp)"

cleanup() {
    rm -f "$TEMP_USERS" "$TEMP_RESULTS" "$TEMP_ERROR"
}
trap cleanup EXIT

confirm() {
    local answer
    read -r -p "$1 [y/N]: " answer
    [[ "$answer" =~ ^([Yy]|[Yy][Ee][Ss])$ ]]
}

# --------------------------------------------------
# 1. Check prerequisites
# --------------------------------------------------

if [[ -z "$IDENTITY_STORE_ID" ]]; then
    echo "ERROR: IDENTITY_STORE_ID is not set."
    echo 'Set it with: export IDENTITY_STORE_ID="your-identity-store-id"'
    exit 1
fi

if ! command -v aws >/dev/null 2>&1; then
    echo "ERROR: AWS CLI is not installed."
    exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "ERROR: Python 3 is not installed."
    exit 1
fi

if [[ ! -f "$CSV_FILE" ]]; then
    echo "ERROR: CSV file not found: $CSV_FILE"
    echo "Usage: $0 [path/to/users.csv]"
    exit 1
fi

if ! aws sts get-caller-identity --region "$AWS_REGION" >/dev/null; then
    echo "ERROR: AWS credentials or region are invalid."
    exit 1
fi

echo "AWS region: $AWS_REGION"
echo "Identity Store ID: $IDENTITY_STORE_ID"
echo "CSV file: $CSV_FILE"
echo

# --------------------------------------------------
# 2. Read and validate the CSV
# --------------------------------------------------

if ! python3 - "$CSV_FILE" > "$TEMP_USERS" <<'PY'
import csv
import io
import re
import sys

path = sys.argv[1]

try:
    with open(path, "r", encoding="utf-8-sig", newline="") as f:
        content = f.read()

    # Ignore blank lines before the header.
    lines = content.splitlines(keepends=True)
    while lines and not lines[0].strip():
        lines.pop(0)

    if not lines:
        raise ValueError("The CSV file is empty.")

    reader = csv.DictReader(io.StringIO("".join(lines), newline=""))

    if not reader.fieldnames:
        raise ValueError("Could not find the CSV header.")

    def normalize(value):
        return re.sub(r"[\s_-]+", "", value.strip().lower())

    headers = {normalize(h): h for h in reader.fieldnames if h}

    aliases = {
        "email": ("email",),
        "firstname": ("firstname", "givenname"),
        "lastname": ("lastname", "familyname", "surname"),
    }

    selected = {}
    for field, possible_names in aliases.items():
        for name in possible_names:
            if name in headers:
                selected[field] = headers[name]
                break
        if field not in selected:
            raise ValueError(
                f"Missing required column: {field}. "
                "Expected Email, FirstName, LastName."
            )

    users = []
    seen_emails = set()

    for line_number, row in enumerate(reader, start=2):
        if not row or all(
            not str(value or "").strip() for value in row.values()
        ):
            continue

        if None in row:
            raise ValueError(
                f"Line {line_number} has extra columns. "
                "Check commas and quotation marks."
            )

        email = (row.get(selected["email"]) or "").strip()
        first_name = (row.get(selected["firstname"]) or "").strip()
        last_name = (row.get(selected["lastname"]) or "").strip()

        if not email or "@" not in email:
            raise ValueError(f"Line {line_number}: invalid or missing email.")
        if not first_name:
            raise ValueError(f"Line {line_number}: missing first name.")
        if not last_name:
            raise ValueError(f"Line {line_number}: missing last name.")

        key = email.casefold()
        if key in seen_emails:
            raise ValueError(
                f"Line {line_number}: duplicate email in CSV: {email}"
            )
        seen_emails.add(key)

        users.append((email, first_name, last_name))

    if not users:
        raise ValueError("No users found in the CSV.")

    # NUL-delimited output safely preserves spaces, apostrophes and commas.
    for user in users:
        for value in user:
            sys.stdout.buffer.write(value.encode("utf-8") + b"\0")

    print(f"Validated {len(users)} user(s).", file=sys.stderr)

except (OSError, UnicodeError, csv.Error, ValueError) as exc:
    print(f"CSV ERROR: {exc}", file=sys.stderr)
    sys.exit(1)
PY
then
    echo "ERROR: Could not read or validate the CSV. No users were created."
    exit 1
fi

# Load validated records into Bash arrays.
USER_EMAILS=()
USER_FIRST_NAMES=()
USER_LAST_NAMES=()

while IFS= read -r -d '' email &&
      IFS= read -r -d '' first_name &&
      IFS= read -r -d '' last_name; do
    USER_EMAILS+=("$email")
    USER_FIRST_NAMES+=("$first_name")
    USER_LAST_NAMES+=("$last_name")
done < "$TEMP_USERS"

USER_COUNT="${#USER_EMAILS[@]}"

if (( USER_COUNT == 0 )); then
    echo "ERROR: No users were loaded. No changes made."
    exit 1
fi

# --------------------------------------------------
# 3. Ask about group assignment
# --------------------------------------------------

GROUP_NAME=""
GROUP_ID=""
CREATE_GROUP="false"

echo
read -r -p "Enter a group name to assign these users to (or press Enter to skip): " GROUP_NAME

if [[ -n "$GROUP_NAME" ]]; then
    GROUP_LOOKUP_JSON="$(
        python3 - "$GROUP_NAME" <<'PY'
import json
import sys
print(json.dumps({
    "UniqueAttribute": {
        "AttributePath": "displayName",
        "AttributeValue": sys.argv[1]
    }
}))
PY
    )"

    if GROUP_ID="$(
        aws identitystore get-group-id \
            --identity-store-id "$IDENTITY_STORE_ID" \
            --alternate-identifier "$GROUP_LOOKUP_JSON" \
            --region "$AWS_REGION" \
            --query GroupId \
            --output text 2>"$TEMP_ERROR"
    )"; then
        echo "Found existing group: $GROUP_NAME"
    else
        if grep -qiE 'ResourceNotFoundException|ResourceNotFound' "$TEMP_ERROR"; then
            echo "Group '$GROUP_NAME' does not exist."

            if confirm "Would you like to create this group?"; then
                CREATE_GROUP="true"
                GROUP_ID=""
            else
                echo "Continuing without group assignment."
                GROUP_NAME=""
            fi
        else
            cat "$TEMP_ERROR" >&2
            echo "ERROR: Could not look up the group. No changes made."
            exit 1
        fi
    fi
fi

# --------------------------------------------------
# 4. Review everything before making changes
# --------------------------------------------------

echo
echo "========== REVIEW =========="
echo "AWS region: $AWS_REGION"
echo "Users to create: $USER_COUNT"
echo "CSV source: $CSV_FILE"
echo

for ((i = 0; i < USER_COUNT; i++)); do
    printf '%d. %s | %s %s\n' \
        "$((i + 1))" \
        "${USER_EMAILS[$i]}" \
        "${USER_FIRST_NAMES[$i]}" \
        "${USER_LAST_NAMES[$i]}"
done

echo

if [[ -n "$GROUP_NAME" ]]; then
    if [[ "$CREATE_GROUP" == "true" ]]; then
        echo "Group: $GROUP_NAME (will be created)"
    else
        echo "Group: $GROUP_NAME (existing group)"
    fi
else
    echo "Group assignment: None"
fi

echo
echo "No AWS resources have been changed yet."

if ! confirm "Proceed with these changes?"; then
    echo "Cancelled. No users or groups were created."
    exit 0
fi

# --------------------------------------------------
# 5. Create the group if needed
# --------------------------------------------------

if [[ "$CREATE_GROUP" == "true" ]]; then
    echo
    echo "Creating group: $GROUP_NAME"

    if ! GROUP_ID="$(
        aws identitystore create-group \
            --identity-store-id "$IDENTITY_STORE_ID" \
            --display-name "$GROUP_NAME" \
            --region "$AWS_REGION" \
            --query GroupId \
            --output text 2>"$TEMP_ERROR"
    )"; then
        cat "$TEMP_ERROR" >&2
        echo "ERROR: Group creation failed. No users were created."
        exit 1
    fi

    echo "Group created successfully. Group ID: $GROUP_ID"
fi

# --------------------------------------------------
# 6. Create users and optionally assign group
# --------------------------------------------------

CREATED=0
FAILED=0
MEMBERSHIP_FAILED=0

echo

for ((i = 0; i < USER_COUNT; i++)); do
    email="${USER_EMAILS[$i]}"
    first_name="${USER_FIRST_NAMES[$i]}"
    last_name="${USER_LAST_NAMES[$i]}"

    echo "[$((i + 1))/$USER_COUNT] Creating $email ..."

    USER_INPUT="$(
        python3 - \
            "$IDENTITY_STORE_ID" "$email" "$first_name" "$last_name" <<'PY'
import json
import sys

store_id, email, first_name, last_name = sys.argv[1:]

print(json.dumps({
    "IdentityStoreId": store_id,
    "UserName": email,
    "DisplayName": f"{first_name} {last_name}",
    "Name": {
        "GivenName": first_name,
        "FamilyName": last_name
    },
    "Emails": [{
        "Value": email,
        "Type": "work",
        "Primary": True
    }]
}))
PY
    )"

    if USER_ID="$(
        aws identitystore create-user \
            --cli-input-json "$USER_INPUT" \
            --region "$AWS_REGION" \
            --query UserId \
            --output text 2>"$TEMP_ERROR"
    )"; then
        CREATED=$((CREATED + 1))
        STATUS="Created; no group assignment"

        if [[ -n "$GROUP_ID" ]]; then
            MEMBERSHIP_INPUT="$(
                python3 - \
                    "$IDENTITY_STORE_ID" "$GROUP_ID" "$USER_ID" <<'PY'
import json
import sys

store_id, group_id, user_id = sys.argv[1:]

print(json.dumps({
    "IdentityStoreId": store_id,
    "GroupId": group_id,
    "MemberId": {
        "UserId": user_id
    }
}))
PY
            )"

            if aws identitystore create-group-membership \
                --cli-input-json "$MEMBERSHIP_INPUT" \
                --region "$AWS_REGION" >/dev/null 2>"$TEMP_ERROR"; then
                STATUS="Created and added to group: $GROUP_NAME"
                echo "  User created and added to group."
            else
                MEMBERSHIP_FAILED=$((MEMBERSHIP_FAILED + 1))
                STATUS="Created; group assignment failed"
                echo "  WARNING: User created, but group assignment failed:"
                cat "$TEMP_ERROR" >&2
            fi
        else
            echo "  User created."
        fi

        printf '%s\0%s\0%s\0' \
            "$email" "$USER_ID" "$STATUS" >> "$TEMP_RESULTS"
    else
        FAILED=$((FAILED + 1))
        STATUS="Creation failed"

        echo "  ERROR: User creation failed:"
        cat "$TEMP_ERROR" >&2

        printf '%s\0%s\0%s\0' \
            "$email" "" "$STATUS" >> "$TEMP_RESULTS"
    fi
done

# --------------------------------------------------
# 7. Export results.csv
# --------------------------------------------------

python3 - "$TEMP_RESULTS" "$RESULTS_FILE" <<'PY'
import csv
import sys

input_path, output_path = sys.argv[1:]

with open(input_path, "rb") as f:
    values = f.read().split(b"\0")

if values and values[-1] == b"":
    values.pop()

if len(values) % 3:
    raise SystemExit("ERROR: Unexpected results data; CSV was not generated.")

with open(output_path, "w", newline="", encoding="utf-8-sig") as f:
    writer = csv.writer(f)
    writer.writerow(["Email", "UserId", "Result"])

    for i in range(0, len(values), 3):
        writer.writerow([
            value.decode("utf-8")
            for value in values[i:i + 3]
        ])
PY

echo
echo "========== SUMMARY =========="
echo "Users requested: $USER_COUNT"
echo "Users created: $CREATED"
echo "User creation failures: $FAILED"
echo "Group assignment failures: $MEMBERSHIP_FAILED"
echo "Results saved to: $RESULTS_FILE"
echo "=============================="

if (( FAILED > 0 || MEMBERSHIP_FAILED > 0 )); then
    exit 1
fi

exit 0
