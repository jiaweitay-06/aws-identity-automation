
#!/usr/bin/env bash
set -uo pipefail

# Configuration: set these environment variables in CloudShell
: "${AWS_REGION:=ap-southeast-5}"
: "${IDENTITY_STORE_ID:?Set IDENTITY_STORE_ID first}"
: "${GROUP_NAME:=kiro-users}"

CSV="./users.csv"
RESULTS="./results.csv"

command -v aws >/dev/null || {
  echo "ERROR: AWS CLI is required."
  exit 1
}

command -v python3 >/dev/null || {
  echo "ERROR: Python 3 is required."
  exit 1
}

[[ -f "$CSV" ]] || {
  echo "ERROR: $CSV not found."
  exit 1
}

# Find the target group
GROUP_LOOKUP=$(python3 -c \
  'import json,sys; print(json.dumps({"UniqueAttribute":{"AttributePath":"displayName","AttributeValue":sys.argv[1]}}))' \
  "$GROUP_NAME")

GROUP_JSON=$(aws identitystore get-group-id \
  --identity-store-id "$IDENTITY_STORE_ID" \
  --alternate-identifier "$GROUP_LOOKUP" \
  --region "$AWS_REGION" --output json) || exit 1

GROUP_ID=$(python3 -c \
  'import json,sys; print(json.load(sys.stdin)["GroupId"])' \
  <<< "$GROUP_JSON")

echo "Target group: $GROUP_NAME ($GROUP_ID)"

printf 'Email,UserId,Result\n' > "$RESULTS"

# Read the CSV. Keep the header: Email,FirstName,LastName
while IFS=, read -r EMAIL FIRST LAST || [[ -n "${EMAIL:-}" ]]; do
  [[ "${EMAIL:-}" == "Email" || -z "${EMAIL:-}" ]] && continue

  EMAIL=$(echo "$EMAIL" | xargs)
  FIRST=$(echo "${FIRST:-}" | xargs)
  LAST=$(echo "${LAST:-}" | xargs)

  echo ""
  echo "Processing $EMAIL"

  # Look up existing user by email
  LOOKUP=$(python3 -c \
    'import json,sys; print(json.dumps({"UniqueAttribute":{"AttributePath":"emails.value","AttributeValue":sys.argv[1]}}))' \
    "$EMAIL")

  USER_JSON=$(aws identitystore get-user-id \
    --identity-store-id "$IDENTITY_STORE_ID" \
    --alternate-identifier "$LOOKUP" \
    --region "$AWS_REGION" --output json 2>/dev/null)
  LOOKUP_STATUS=$?

  if [[ $LOOKUP_STATUS -eq 0 ]]; then
    USER_ID=$(python3 -c \
      'import json,sys; print(json.load(sys.stdin)["UserId"])' \
      <<< "$USER_JSON")
    echo "User already exists."
  else
    # Don't treat permission/network errors as missing users.
    # Confirm the user is absent through a filtered list query.
    FILTER=$(python3 -c \
      'import json,sys; print(json.dumps([{"AttributePath":"Emails.Value","AttributeValue":sys.argv[1]}]))' \
      "$EMAIL")

    SEARCH=$(aws identitystore list-users \
      --identity-store-id "$IDENTITY_STORE_ID" \
      --filters "$FILTER" \
      --region "$AWS_REGION" --output json 2>&1) || {
        echo "ERROR: Could not verify whether user exists: $SEARCH"
        printf '"%s",,"Lookup failed"\n' "$EMAIL" >> "$RESULTS"
        continue
      }

    COUNT=$(python3 -c \
      'import json,sys; print(len(json.load(sys.stdin).get("Users",[])))' \
      <<< "$SEARCH")

    if [[ "$COUNT" -gt 0 ]]; then
      echo "ERROR: User lookup was unsuccessful but matching email exists."
      printf '"%s",,"Lookup ambiguous"\n' "$EMAIL" >> "$RESULTS"
      continue
    fi

    if [[ -z "$FIRST" || -z "$LAST" ]]; then
      echo "ERROR: FirstName and LastName are required for a new user."
      printf '"%s",,"Missing name"\n' "$EMAIL" >> "$RESULTS"
      continue
    fi

    echo "Creating user..."

    NAME_JSON=$(python3 -c \
      'import json,sys; print(json.dumps({"GivenName":sys.argv[1],"FamilyName":sys.argv[2]}))' \
      "$FIRST" "$LAST")

    EMAIL_JSON=$(python3 -c \
      'import json,sys; print(json.dumps([{"Value":sys.argv[1],"Type":"Work","Primary":True}]))' \
      "$EMAIL")

    CREATED=$(aws identitystore create-user \
      --identity-store-id "$IDENTITY_STORE_ID" \
      --user-name "$EMAIL" \
      --display-name "$FIRST $LAST" \
      --name "$NAME_JSON" \
      --emails "$EMAIL_JSON" \
      --region "$AWS_REGION" --output json 2>&1) || {
        echo "ERROR creating user: $CREATED"
        printf '"%s",,"Create failed"\n' "$EMAIL" >> "$RESULTS"
        continue
      }

    USER_ID=$(python3 -c \
      'import json,sys; print(json.load(sys.stdin)["UserId"])' \
      <<< "$CREATED")

    echo "Created user: $USER_ID"
  fi

  # Check ALL pages of group membership
  NEXT_TOKEN=""
  IS_MEMBER=false
  MEMBERSHIP_ERROR=false

  while :; do
    ARGS=(
      identitystore list-group-memberships
      --identity-store-id "$IDENTITY_STORE_ID"
      --group-id "$GROUP_ID"
      --region "$AWS_REGION"
      --output json
    )

    [[ -n "$NEXT_TOKEN" ]] && ARGS+=(--next-token "$NEXT_TOKEN")

    PAGE=$(aws "${ARGS[@]}" 2>&1) || {
      echo "ERROR checking membership: $PAGE"
      MEMBERSHIP_ERROR=true
      break
    }

    FOUND=$(python3 -c \
      'import json,sys; d=json.load(sys.stdin); uid=sys.argv[1]; print(any(m.get("MemberId",{}).get("UserId")==uid for m in d.get("Memberships",[])))' \
      "$USER_ID" <<< "$PAGE")

    [[ "$FOUND" == "True" ]] && IS_MEMBER=true

    NEXT_TOKEN=$(python3 -c \
      'import json,sys; print(json.load(sys.stdin).get("NextToken",""))' \
      <<< "$PAGE")

    [[ -z "$NEXT_TOKEN" || "$IS_MEMBER" == true ]] && break
  done

  if [[ "$MEMBERSHIP_ERROR" == true ]]; then
    printf '"%s","%s","Membership check failed"\n' "$EMAIL" "$USER_ID" >> "$RESULTS"
    continue
  fi

  if [[ "$IS_MEMBER" == true ]]; then
    echo "Already in $GROUP_NAME; skipping."
    printf '"%s","%s","Already a member"\n' "$EMAIL" "$USER_ID" >> "$RESULTS"
    continue
  fi

  MEMBER_JSON=$(python3 -c \
    'import json,sys; print(json.dumps({"UserId":sys.argv[1]}))' \
    "$USER_ID")

  if aws identitystore create-group-membership \
    --identity-store-id "$IDENTITY_STORE_ID" \
    --group-id "$GROUP_ID" \
    --member-id "$MEMBER_JSON" \
    --region "$AWS_REGION" >/dev/null; then

    echo "Added to $GROUP_NAME."
    printf '"%s","%s","Added successfully"\n' "$EMAIL" "$USER_ID" >> "$RESULTS"
  else
    echo "ERROR adding user to group."
    printf '"%s","%s","Membership creation failed"\n' "$EMAIL" "$USER_ID" >> "$RESULTS"
  fi
done < "$CSV"

echo ""
echo "Finished. Results saved to $RESULTS"
cat "$RESULTS"
