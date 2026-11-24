# trophyquest-infra

Terraform configuration for TrophyQuest production. Run Terraform from
`terraform/envs/prod` with access to the existing S3 state backend.

## Image uploader Lambda

Terraform provisions `trophyquest-image-uploader` in `eu-west-3` with Python
3.12 on ARM64, a published version, the `prod` alias, and a disabled
EventBridge schedule. The first apply also imports the existing execution role,
Scheduler role and CloudWatch log group. It replaces the two imported roles'
managed policy attachments with dedicated inline policies.

Build the bootstrap ZIP from the sibling `trophyquest-images` checkout using a
Python virtual environment with pip and the `zip` CLI:

```sh
cd ../trophyquest-images
bash scripts/package-lambda.sh 3.12 arm64
cd ../trophyquest-infra/terraform/envs/prod
terraform init
terraform validate
terraform plan -out=image-uploader.tfplan
```

The default ZIP path is `trophyquest-images/out/image-uploader.zip` in the
workspace. Override `image_uploader_zip_path` for a different checkout layout.
Keep the same artifact available for Terraform runs. Terraform uploads it to
`trophyquest-artifacts` under a content-addressed key on apply. The GitHub
release workflow owns subsequent code updates and moves `prod` after a new
version is active. After a Terraform configuration change, promote the newly
published version explicitly before expecting that configuration on `prod`.

### Before the first invocation

1. Apply the web service Liquibase image-cache changeset. Create a dedicated
   PostgreSQL login and grant access from a database administrator account.
   Supply the actual login with the `uploader_role` psql variable.

   ```sh
   psql --dbname="$TROPHYQUEST_DATABASE" --set=uploader_role=trophyquest_image_uploader \
     --file=image_uploader_postgres_grants.sql
   ```

2. Store a JSON secret value with `host`, `port`, `dbname`, `username` and
   `password` in the secret identified by the `image_uploader_postgres_secret_arn`
   output. Terraform manages the secret metadata and IAM policy. Use Secrets
   Manager directly to set the value.
3. Check that the PostgreSQL endpoint is reachable from a Lambda outside your
   VPC. If PostgreSQL requires private networking, configure the function's
   VPC access, private subnets, security group and outbound HTTPS before
   invoking it.
4. Set `AWS_ROLE_ARN` to `image_uploader_deploy_role_arn` and `AWS_REGION` to
   `eu-west-3` in the `trophyquest-images` GitHub deployment environment
   `prod`. Restrict deployment to `main`. Detach the legacy
   `tq-deploy-lambda-image-uploader-policy` from the shared
   `github-deploy-role` so the dedicated role handles uploader releases.
5. Invoke the `prod` alias manually with one nonzero limit of `1` and the
   other three limits set to `0`. Check the CloudWatch batch summary for one
   saved image and zero failures, the PostgreSQL URL and an HTTPS GET of the
   image. Keep the schedule disabled until the smoke test and a GitHub release
   have passed.

## IGDB screenshot backfill

Build the ZIP with `bash scripts/package-screenshot-backfill.sh` from
`trophyquest-igdb` in a Python environment with pip and the ZIP CLI. Run
`terraform plan -out=screenshot-backfill.tfplan` from `terraform/envs/prod`.
Terraform owns the ZIP, published version and `prod` alias. Invoke the alias
manually.

Before the first invocation, create a dedicated PostgreSQL login and run
`screenshot_backfill_postgres_grants.sql` as a database administrator with
`psql --set=backfill_role=trophyquest_screenshot_backfill` against the production
database. Populate the PostgreSQL secret with `host`, `port`, `dbname`,
`username` and `password`. Populate the Twitch secret with `client_id` and
`client_secret`, or set `screenshot_backfill_twitch_secret_arn` before the first
apply to reuse a secret in that format. A reused secret encrypted with a
customer-managed KMS key also requires `kms:Decrypt` on that key.

Verify the network path to PostgreSQL from a Lambda outside the VPC and
outbound HTTPS to Secrets Manager, Twitch and IGDB. Assume the role from
`screenshot_backfill_operator_role_arn` as `trophyquest-admin` to invoke the alias.

Invoke `prod` synchronously with `{"game_ids":[1001]}`, using an actual matched
IGDB game ID. Check the returned counts and the new rows in `igdb.screenshot`.
Replaying the same payload should insert zero additional rows. To scan,
start with `{"mode":"scan","limit":50}` and pass the returned
`next_after_game_id` as `after_game_id` on the next invocation. Stop when
the cursor is null. If a request fails, retry the same payload.
