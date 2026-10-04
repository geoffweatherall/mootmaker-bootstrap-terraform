# mootmaker-bootstrap-terraform

Creates the shared S3 bucket that the other `mootmaker-*` projects use as
Terraform remote state storage, so state isn't kept only on one person's
laptop and everyone applying Terraform reads/writes the same state.

## First-time setup

Run once, with AWS credentials for the target account active:

```
./deploy.sh
```

This creates a bucket named `remote-state-<aws-account-id>` (e.g.
`remote-state-431071856068`) and prints its name at the end.

The bucket is **versioned**, so a corrupted or truncated state write can be
rolled back by restoring the previous version of that object. Old versions
expire after 30 days, and delete markers with nothing behind them are
removed, so versioning does not make the bucket grow without bound.

### How `deploy.sh` avoids the chicken-and-egg problem

This project's own state needs to live in the bucket it creates, same as
every other project — but on the very first run, that bucket doesn't exist
yet, so Terraform can't initialise an S3 backend pointed at it. `deploy.sh`
handles this in three steps:

1. It first tries `terraform init -backend-config=backend.hcl -migrate-state
   -force-copy`. On a fresh checkout this fails (the bucket doesn't exist),
   so it falls back to a plain local `terraform init`.
2. `terraform apply` runs against that local state, creating the bucket.
3. It runs the backend-config init again. The bucket now exists, so this
   succeeds and copies the local state into it, under the key
   `bootstrap/terraform.tfstate` in the same bucket every other project uses.

From then on, `deploy.sh` is idempotent: both init attempts just reconnect to
the already-migrated remote state, so re-running it behaves like any other
project's `deploy.sh`.

We deliberately did **not** commit `terraform.tfstate` to git as a way around
this. It would have worked, but state files are merge-hostile, and while
today's state (an S3 bucket and its access/encryption settings) has nothing
secret in it, that stops being true the moment this project grows — and
committing it would leave this one project without the locking that
`use_lockfile` gives everything else. Migrating into the bucket keeps this
project consistent with the rest instead of a special case.

A leftover local `deploy/terraform/terraform.tfstate` file remains after the
migration (Terraform doesn't delete the source state) — it's stale, is
already covered by `.gitignore`, and can be deleted or left alone.

The bucket has `prevent_destroy` set, so a stray `terraform destroy` here
can't take out every project's state in one go. To genuinely decommission
it, remove that lifecycle block first.

## Configuring other projects to use remote state

Each `mootmaker-*` project's `deploy/terraform/` directory has:

- A `backend "s3" {}` block (empty) in `versions.tf`, declaring that the
  project uses an S3 backend without hardcoding the details.
- A checked-in `backend.hcl` file supplying the parts that don't change per
  deploy:

  ```hcl
  bucket       = "remote-state-431071856068"
  region       = "us-east-1"
  use_lockfile = true
  ```

- Scripts (`deploy.sh`, `undeploy.sh`, `authenticate.sh`) that pass `key`
  on the command line instead, computed from the **environment** being
  deployed (see the [mootmaker project README](https://github.com/geoffweatherall/mootmaker#multi-environment-deployments)
  for the full multi-environment design):

  ```
  terraform init -backend-config=backend.hcl -backend-config="key=<environment>/<project-name>/terraform.tfstate"
  ```

  giving a layout like `test/room-booking-api/terraform.tfstate`,
  `production/room-booking-webapp/terraform.tfstate`, or
  `bob/room-booking-api/terraform.tfstate` for a developer's personal sandbox.

`backend.hcl` isn't secret — it just says which bucket to read and write
state from — so it's committed to git rather than ignored.

If the state bucket ever changes (e.g. a new AWS account), update the
`bucket` value in each project's `backend.hcl` and re-run `terraform init`
with the same `-backend-config` flags plus `-reconfigure`.

### Adding a new project

Give it its own `<project-name>` segment in the `key` passed by its scripts
(e.g. `<environment>/<project-name>/terraform.tfstate`) so its state doesn't
collide with another project's in the shared bucket.

## Locking

State locking uses Terraform's native S3 lockfile support (`use_lockfile =
true`), not a DynamoDB table. This requires Terraform >= 1.10 (all projects'
`versions.tf` require this). When two people (or the same person twice)
attempt `apply` against the same state key concurrently, the second one
blocks/fails until the first finishes.

## Why no bucket versioning

Versioning was deliberately left off to keep this simple/cheap. This means
there's no built-in way to recover a previous version of the state file if
it's overwritten or corrupted — if that risk matters later, versioning can be
turned on by adding an `aws_s3_bucket_versioning` resource in `s3.tf`.
