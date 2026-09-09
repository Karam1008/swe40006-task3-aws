#!/bin/bash
#
# SWE40006 Deployment Portfolio Task 3 — LAMP provisioning
#
# Installs Apache, PHP and the MariaDB client on a bare Amazon Linux 2023
# instance. Used as user data when launching SWE40006-WebServer-Restore for the
# Task 3.2 restore demonstration, and as the base for building the golden AMI.
#
# Note: the MariaDB *server* is intentionally NOT installed. From Task 3.2
# onward the database lives on Amazon RDS; only the client is needed, for
# mysqldump and for verifying connectivity from the instance.
#
set -eu

REGION="ap-southeast-2"

dnf update -y

# httpd          Apache web server
# php-mysqlnd    PHP's native MySQL driver — required by WordPress
# php-gd         image handling for media uploads
# php-xml        required by several WordPress core features
# mariadb105     client only, for mysqldump and connectivity checks
dnf install -y httpd php php-mysqlnd php-gd php-xml mariadb105

systemctl enable --now httpd

# RDS trust store — RDS refuses unencrypted connections
curl -s -o /home/ec2-user/rds-ca.pem \
  "https://truststore.pki.rds.amazonaws.com/${REGION}/${REGION}-bundle.pem"
chown ec2-user:ec2-user /home/ec2-user/rds-ca.pem

# ALB health check endpoint
echo "OK" > /var/www/html/health.html

chown -R apache:apache /var/www/html
chmod -R 755 /var/www/html

echo "LAMP provisioning complete"
