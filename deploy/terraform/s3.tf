data "aws_caller_identity" "current" {}

# Shared Terraform remote state storage for all mootmaker-* projects.
# prevent_destroy guards against an accidental `terraform destroy` wiping out
# every project's state in one go.
resource "aws_s3_bucket" "remote_state" {
  bucket = "remote-state-${data.aws_caller_identity.current.account_id}"

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_public_access_block" "remote_state" {
  bucket = aws_s3_bucket.remote_state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "remote_state" {
  bucket = aws_s3_bucket.remote_state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Versioning, so a corrupted or truncated state write has a recovery path (found while checking
# mootmaker#77). Without it, a bad write to any project's state is unrecoverable, and every resource
# that state tracked is orphaned.
resource "aws_s3_bucket_versioning" "remote_state" {
  bucket = aws_s3_bucket.remote_state.id

  versioning_configuration {
    status = "Enabled"
  }
}

# ...and a bound on what versioning keeps, because principles.md's "nothing accumulates without a
# bound" applies to this bucket as much as anything. Every ephemeral environment and every release
# writes state several times, so unbounded old versions would grow with time rather than with use.
#
# 30 days is long enough to notice a bad write and roll back. Deleting an object under versioning
# leaves a delete marker, and the sweep and teardown scripts delete state objects routinely, so
# markers with nothing behind them are expired too.
resource "aws_s3_bucket_lifecycle_configuration" "remote_state" {
  bucket = aws_s3_bucket.remote_state.id

  rule {
    id     = "bound-old-state-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 30
    }

    expiration {
      expired_object_delete_marker = true
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }

  depends_on = [aws_s3_bucket_versioning.remote_state]
}
