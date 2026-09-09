#!/bin/bash
#
# SWE40006 Deployment Portfolio Task 3 — Restore from Amazon S3
#
# Downloads an application archive from the S3 backup bucket and extracts it
# into the Apache document root of a freshly provisioned instance.
#
# Because wp-config.php is inside the archive, the restored instance is already
# configured to reach RDS with TLS enabled — no manual reconfiguration needed.
# This is what makes the compute layer genuinely interchangeable, and is the
# precondition for the Auto Scaling Group built in Task 3.3.
#
# Usage:
#   export S3_BUCKET="swe40006-backup-XXXXXXXXX"
#   ./restore-from-s3.sh                              # restores the latest archive
#   ./restore-from-s3.sh wordpress-files-2026-09-08.tar.gz   # restores a specific one
#
set -euo pipefail

: "${S3_BUCKET:?Set S3_BUCKET to the backup bucket name, without the s3:// prefix}"

WEBROOT="${WEBROOT:-/var/www/html}"
REGION="${AWS_REGION:-ap-southeast-2}"
CA_BUNDLE="${CA_BUNDLE:-/home/ec2-user/rds-ca.pem}"
ARCHIVE_NAME="${1:-}"

echo "==> Available backups"
aws s3 ls "s3://${S3_BUCKET}/backups/" --human-readable

if [ -z "${ARCHIVE_NAME}" ]; then
  echo "==> No archive specified, selecting the most recent files archive"
  ARCHIVE_NAME=$(aws s3 ls "s3://${S3_BUCKET}/backups/" \
    | grep 'wordpress-files-.*\.tar\.gz$' \
    | sort \
    | tail -1 \
    | awk '{print $4}')
fi

if [ -z "${ARCHIVE_NAME}" ]; then
  echo "ERROR: no application archive found in s3://${S3_BUCKET}/backups/" >&2
  exit 1
fi

echo "==> Restoring ${ARCHIVE_NAME}"
aws s3 cp "s3://${S3_BUCKET}/backups/${ARCHIVE_NAME}" "/tmp/${ARCHIVE_NAME}"

# Verify the download before extraction. Skipping this produces a confusing
# "tar: Cannot open: No such file or directory" that looks like a tar fault
# when the real failure was upstream.
if [ ! -s "/tmp/${ARCHIVE_NAME}" ]; then
  echo "ERROR: downloaded archive is empty" >&2
  exit 1
fi
ls -lh "/tmp/${ARCHIVE_NAME}"

echo "==> Extracting into ${WEBROOT}"
sudo tar -xzf "/tmp/${ARCHIVE_NAME}" -C "${WEBROOT}"

echo "==> Setting ownership for the Apache worker user"
sudo chown -R apache:apache "${WEBROOT}"
sudo chmod -R 755 "${WEBROOT}"

# The CA bundle lives outside the document root and is therefore not inside the
# archive. Without it the restored WordPress cannot complete its TLS handshake
# to RDS and reports a generic database connection error.
if [ ! -f "${CA_BUNDLE}" ]; then
  echo "==> Fetching RDS CA bundle"
  curl -s -o "${CA_BUNDLE}" \
    "https://truststore.pki.rds.amazonaws.com/${REGION}/${REGION}-bundle.pem"
fi

echo "==> Restarting Apache"
sudo systemctl restart httpd

echo "==> Verifying restored configuration"
sudo grep -E "DB_HOST|MYSQL_CLIENT_FLAGS|WP_HOME" "${WEBROOT}/wp-config.php" || true
curl -I -s http://localhost/health.html | head -1

cat <<'NOTE'

Restore complete.

If the site redirects to a different host, WordPress is using the canonical URL
stored in the shared RDS database. Set WP_HOME and WP_SITEURL in wp-config.php
to the address this instance should present — behind an ALB, that is the load
balancer DNS name.
NOTE
