#!/bin/bash
#
# SWE40006 Deployment Portfolio Task 3 — Launch Template user data
#
# Runs on every instance launched by the Auto Scaling Group swe40006-asg.
# The AMI (swe40006-wordpress-ami) already contains Apache, PHP, WordPress and a
# wp-config.php pointed at RDS, so this script performs only the per-boot
# configuration that cannot sensibly be baked into an image.
#
# Executed as root by cloud-init. Output lands in /var/log/cloud-init-output.log
#
set -u

REGION="ap-southeast-2"
WEBROOT="/var/www/html"

# ---------------------------------------------------------------------------
# 1. Web server
# ---------------------------------------------------------------------------
systemctl enable --now httpd

# ---------------------------------------------------------------------------
# 2. SSM Agent
#    Preinstalled on Amazon Linux 2023. Started explicitly so that an instance
#    whose IAM permissions were attached after a previous boot registers
#    immediately, rather than waiting out the agent's exponential backoff.
# ---------------------------------------------------------------------------
systemctl enable --now amazon-ssm-agent
systemctl restart amazon-ssm-agent

# ---------------------------------------------------------------------------
# 3. RDS certificate authority bundle
#    RDS enforces require_secure_transport=ON, so clients need the trust store.
#    Fetched per boot rather than baked in, so CA rotation is picked up.
# ---------------------------------------------------------------------------
curl -s -o /home/ec2-user/rds-ca.pem \
  "https://truststore.pki.rds.amazonaws.com/${REGION}/${REGION}-bundle.pem"
chown ec2-user:ec2-user /home/ec2-user/rds-ca.pem

# ---------------------------------------------------------------------------
# 4. ALB health check endpoint
#    Must return a flat 200. WordPress answers "/" with a 302 redirect, which
#    the target group reads as unhealthy against its 200 success code.
# ---------------------------------------------------------------------------
echo "OK" > "${WEBROOT}/health.html"

# ---------------------------------------------------------------------------
# 5. Instance identity page
#    Diagnostic endpoint that makes ALB request distribution directly
#    observable in a browser. Uses IMDSv2 token-based metadata access.
# ---------------------------------------------------------------------------
TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")

IID=$(curl -s -H "X-aws-ec2-metadata-token: ${TOKEN}" \
  http://169.254.169.254/latest/meta-data/instance-id)

AZ=$(curl -s -H "X-aws-ec2-metadata-token: ${TOKEN}" \
  http://169.254.169.254/latest/meta-data/placement/availability-zone)

cat > "${WEBROOT}/instance.html" <<EOF
<!DOCTYPE html>
<html lang="en">
<head><meta charset="utf-8"><title>SWE40006 — Instance Identity</title></head>
<body style="font-family:system-ui,sans-serif;padding:2rem;line-height:1.6">
  <h1>SWE40006 — Served by</h1>
  <p><b>Instance ID:</b> ${IID}</p>
  <p><b>Availability Zone:</b> ${AZ}</p>
  <p><b>Booted:</b> $(date -u '+%Y-%m-%d %H:%M:%S UTC')</p>
</body>
</html>
EOF

# ---------------------------------------------------------------------------
# 6. Ownership and restart
# ---------------------------------------------------------------------------
chown -R apache:apache "${WEBROOT}"
chmod -R 755 "${WEBROOT}"
systemctl restart httpd

echo "user-data complete: ${IID} in ${AZ}"
