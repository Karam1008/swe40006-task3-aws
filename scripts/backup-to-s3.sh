#!/bin/bash
#
# SWE40006 Deployment Portfolio Task 3 — Backup to Amazon S3
#
# Produces two artefacts and uploads both to the S3 backup bucket:
#   1. A gzipped tar of the Apache document root (WordPress core, themes,
#      plugins, uploads and wp-config.php)
#   2. A logical dump of the WordPress database, taken from RDS over TLS
#
# Credentials come from the EC2 instance role (swe40006-ec2-s3-role) via the
# instance metadata service. No access keys are used or stored.
#
# The database password is not accepted as an argument or environment variable —
# mysqldump prompts for it, so it never enters shell history or the process list.
#
# Usage:
#   export RDS_ENDPOINT="swe40006-rds.chm0e2oc24zi.ap-southeast-2.rds.amazonaws.com"
#   export S3_BUCKET="swe40006-backup-104809887"
#   ./backup-to-s3.sh
#
set -euo pipefail

: "${RDS_ENDPOINT:?Set RDS_ENDPOINT to the RDS endpoint hostname}"
: "${S3_BUCKET:?Set S3_BUCKET to the backup bucket name, without the s3:// prefix}"

DB_NAME="${DB_NAME:-wordpress_db}"
DB_USER="${DB_USER:-wp_user}"
WEBROOT="${WEBROOT:-/var/www/html}"
CA_BUNDLE="${CA_BUNDLE:-/home/ec2-user/rds-ca.pem}"
WORKDIR="${WORKDIR:-/home/ec2-user}"
DATE="$(date +%F)"

FILES_ARCHIVE="${WORKDIR}/wordpress-files-${DATE}.tar.gz"
DB_DUMP="${WORKDIR}/wordpress-db-${DATE}.sql"

if [ ! -f "${CA_BUNDLE}" ]; then
  echo "ERROR: RDS CA bundle not found at ${CA_BUNDLE}" >&2
  echo "Download it with:" >&2
  echo "  curl -o ${CA_BUNDLE} https://truststore.pki.rds.amazonaws.com/ap-southeast-2/ap-southeast-2-bundle.pem" >&2
  exit 1
fi

SSL_OPTS="--ssl-ca=${CA_BUNDLE} --ssl-verify-server-cert"

echo "==> Confirming credential source"
# Returns an assumed-role ARN when the instance role is in use, rather than an
# IAM user ARN. This is the verification that no static keys are involved.
aws sts get-caller-identity

echo "==> Archiving application files from ${WEBROOT}"
sudo tar -czf "${FILES_ARCHIVE}" -C "${WEBROOT}" .
sudo chown "$(id -u):$(id -g)" "${FILES_ARCHIVE}"

echo "==> Dumping ${DB_NAME} from RDS over TLS"
# --single-transaction takes a consistent snapshot inside a transaction rather
# than locking tables, so the live site is not interrupted.
mysqldump -h "${RDS_ENDPOINT}" -u "${DB_USER}" -p ${SSL_OPTS} \
  --single-transaction --routines --triggers \
  "${DB_NAME}" > "${DB_DUMP}"

echo "==> Verifying artefacts"
# Shell redirection creates the output file whether or not the command
# succeeded, so a zero-byte dump is a real and silent failure mode.
for f in "${FILES_ARCHIVE}" "${DB_DUMP}"; do
  if [ ! -s "${f}" ]; then
    echo "ERROR: ${f} is empty — aborting before upload" >&2
    exit 1
  fi
done
ls -lh "${FILES_ARCHIVE}" "${DB_DUMP}"
echo "Tables in dump: $(grep -c 'CREATE TABLE' "${DB_DUMP}")"

echo "==> Uploading to s3://${S3_BUCKET}/backups/"
aws s3 cp "${FILES_ARCHIVE}" "s3://${S3_BUCKET}/backups/"
aws s3 cp "${DB_DUMP}"       "s3://${S3_BUCKET}/backups/"

echo "==> Bucket contents"
aws s3 ls "s3://${S3_BUCKET}/backups/" --human-readable

echo "Backup complete."
