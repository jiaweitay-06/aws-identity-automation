The script performs real user and group changes. Test it with one or two accounts first.



Your CloudShell role needs the appropriate Identity Store permissions.



The script assumes the built-in IAM Identity Center identity store is the source of users.



If you use an external identity provider, user provisioning should generally happen through that provider.



This script is designed for a simple CSV with no commas embedded in names. Use a proper CSV parser if names may contain commas.



For company automation, pin the GitHub download to a reviewed commit rather than always downloading the latest main branch.

## How to use

```bash
aws sso-admin list-instances --region ap-southeast-1
nano users.csv

curl -fSL -o add-users.sh \
"https://raw.githubusercontent.com/jiaweitay-06/aws-identity-automation/refs/heads/main/add-users.sh"

export IDENTITY_STORE_ID="d-xxxxxxxxx"
export AWS_REGION="ap-southeast-1"

chmod +x add-users.sh
./add-users.sh users.csv
```


## Proper CSV format

```bash
Email,FirstName,LastName
john@example.com,John,Doe
```
