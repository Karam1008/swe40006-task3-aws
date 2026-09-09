# Architecture Reference

Resource inventory and configuration for the SWE40006 Task 3 deployment. Recorded at this
level of detail so the stack could be reproduced, or converted to CloudFormation or CDK,
without re-deriving the parameters from the console.

**Region:** `ap-southeast-2` (Asia Pacific — Sydney)
**VPC:** default, public subnets in `ap-southeast-2a` and `ap-southeast-2b`

---

## Security group matrix

Every rule authorises by security group reference rather than by CIDR range, except at the
public edge where an IP range is unavoidable. Referencing a group authorises *membership*
rather than a network location, so the rule survives instance replacement, IP reassignment
and Auto Scaling activity without ever needing to be edited.

| Group | Direction | Protocol / Port | Source or destination | Purpose |
|---|---|---|---|---|
| `swe40006-alb-sg` | Inbound | TCP 80 | `0.0.0.0/0` | Public HTTP to the load balancer |
| `swe40006-alb-sg` | Inbound | TCP 443 | `0.0.0.0/0` | Reserved for a future HTTPS listener |
| `swe40006-web-sg` | Inbound | TCP 80 | `swe40006-alb-sg` | Application traffic from the ALB only |
| `swe40006-rds-sg` | Inbound | TCP 3306 | `swe40006-web-sg` | Database access from the web tier only |
| all | Outbound | All | `0.0.0.0/0` | Package updates, S3, and the SSM Agent's outbound channel |

**Removed at Task 3.4:** `swe40006-web-sg` inbound TCP 22. Administrative access moved to
SSM Session Manager, which requires no inbound rule at all.

At Pass level a single group, `launch-wizard-1`, opened ports 22, 80 and 443 to
`0.0.0.0/0`. It was superseded by the three groups above.

---

## Compute

### AMI — `swe40006-wordpress-ami`

Built from `SWE40006-WebServer-Pass` after WordPress was configured against RDS and the
ALB. Contains Apache, PHP 8.5, WordPress and a complete `wp-config.php`.

Chosen over a minimal base AMI plus a long boot-time provisioning script. Instances boot
in roughly sixty seconds rather than three to five minutes, which affects how quickly the
Auto Scaling Group can replace a failed instance. It also eliminates a failure class: a
boot script that installs packages can fail midway if a repository is unreachable,
producing an instance that is running but broken. The trade-off is that the image must be
rebuilt for every application change.

### Launch template — `swe40006-launch-template`

| Setting | Value |
|---|---|
| AMI | `swe40006-wordpress-ami` |
| Instance type | `t3.micro` |
| Security group | `swe40006-web-sg` |
| IAM instance profile | `swe40006-ec2-s3-role` |
| Subnet | **not set** — controlled by the ASG |
| Metadata | IMDSv2, token required |
| User data | `scripts/user-data.sh` |

The subnet is deliberately omitted. Pinning one in the template would tie every instance
to a single Availability Zone and silently defeat the multi-zone requirement, because the
ASG would be unable to distribute instances.

### Auto Scaling Group — `swe40006-asg`

| Setting | Value |
|---|---|
| Availability Zones | `ap-southeast-2a`, `ap-southeast-2b` |
| Desired / Min / Max | 2 / 2 / 4 |
| Target group | `swe40006-tg` |
| Health check type | **ELB + EC2** |
| Health check grace period | 300 s |
| Scaling policies | none — fixed capacity per the task specification |

Enabling ELB health checks is the significant setting. EC2 health checks assess only
hypervisor-level instance status, so an instance whose Apache process had crashed would
pass indefinitely while serving nothing. With ELB checks enabled the ASG acts on the same
signal the load balancer uses.

Minimum 2 rather than 1: with a minimum of one, the interval between terminating a failed
instance and its replacement passing health checks is a complete outage.

---

## Load balancing

### Target group — `swe40006-tg`

| Setting | Value | Rationale |
|---|---|---|
| Protocol / Port | HTTP 80 | |
| Health check path | `/health.html` | See below |
| Healthy / Unhealthy threshold | 2 / 2 | Fast detection, minimal flapping |
| Timeout / Interval | 5 s / 10 s | Detects failure within ~20 s |
| Success codes | 200 | Explicitly excludes 3xx |

The health check path is the most consequential single setting in the deployment.
WordPress answers a request for `/` with an HTTP 302 redirect, and the default success
code is 200. Left at the default, every target is marked unhealthy, the ASG terminates and
replaces them in a loop, and the ALB returns 503 to all traffic. A static file returning a
flat 200 decouples infrastructure health checking from application routing behaviour.

### Load balancer — `swe40006-alb`

Internet-facing Application Load Balancer, IPv4, mapped to public subnets in both
Availability Zones, single HTTP listener on port 80 forwarding to `swe40006-tg`, attached
to `swe40006-alb-sg`.

Mapping across two AZs is what makes the multi-zone requirement meaningful: an ALB
provisions nodes in each mapped subnet, so with one zone mapped an AZ failure would take
the load balancer offline regardless of how many instances were healthy elsewhere.

---

## Data

### RDS — `swe40006-rds`

| Setting | Value |
|---|---|
| Engine | MariaDB |
| Instance class | `db.t4g.micro` |
| Storage | 20 GiB gp3, autoscaling **disabled** |
| Multi-AZ | No — not free-tier eligible |
| Publicly accessible | **No** |
| Security group | `swe40006-rds-sg` |
| Initial database | `wordpress_db` |
| Encryption at rest | Enabled |
| Automated backups | Enabled, 7-day retention |
| Enhanced Monitoring / Performance Insights | Disabled — both billable |

Engine matched to the MariaDB 10.5 source, eliminating dump compatibility risk. Storage
autoscaling was disabled deliberately: it can silently grow storage beyond the free
allowance.

**TLS is enforced.** The default parameter group sets `require_secure_transport = ON`.
Clients supply the regional CA bundle from
`https://truststore.pki.rds.amazonaws.com/ap-southeast-2/ap-southeast-2-bundle.pem`.
Disabling the parameter was rejected as a weakening of the security posture.

Application user grants are scoped to `wordpress_db.*`, not `*.*`. The credentials sit in
plain text in `wp-config.php` on an internet-facing web server and must be treated as
compromisable, so the blast radius of a web-tier compromise is limited to the WordPress
schema.

### S3 — `swe40006-backup-<student-id>`

| Setting | Value |
|---|---|
| Block all public access | Enabled |
| Versioning | Enabled |
| Default encryption | SSE-S3 |
| Key prefix | `backups/` |

Public access blocking is not optional here: the bucket holds a database dump containing
WordPress user records and password hashes, plus an archive containing `wp-config.php`
with live database credentials. Exposure would be a credential disclosure, not merely a
data leak.

Versioning turns an overwrite or deletion into a recoverable event. Without it, a
corrupted backup uploaded over a good one destroys the only copy.

---

## Identity and access

### `swe40006-ec2-s3-role`

| Policy | Type | Purpose |
|---|---|---|
| `swe40006-s3-backup-policy` | Customer managed | `s3:ListBucket`, `s3:PutObject`, `s3:GetObject` on one bucket |
| `AmazonSSMManagedInstanceCore` | AWS managed | Session Manager and Fleet Manager registration |

Attached to every instance via the launch template. No access keys exist anywhere in the
deployment.

The custom policy grants three actions against one bucket. It cannot delete objects,
cannot access any other bucket, and cannot enumerate the account's buckets.
`AmazonS3FullAccess` was rejected as excessive for a credential held on an internet-facing
web server.

`AmazonSSMManagedInstanceCore` was chosen over `AmazonSSMFullAccess` for the same reason:
it grants only the API calls the agent itself needs — instance information updates, the
message delivery channels, and limited S3 access for agent updates — and no ability to act
on other resources in the account.

---

## Monitoring

### SNS — `swe40006-alerts`

Standard topic with a confirmed email subscription. An unconfirmed subscription remains in
`PendingConfirmation` and silently discards all messages, which is a common cause of alarms
appearing to fire without notification.

### CloudWatch — `swe40006-high-cpu-alarm`

| Setting | Value |
|---|---|
| Metric | `CPUUtilization`, dimensioned by Auto Scaling Group |
| Statistic / Period | Average / 300 s |
| Threshold | > 70% |
| Datapoints to alarm | 1 of 1 |
| Missing data | Treated as missing |
| Actions | ALARM → `swe40006-alerts`, OK → `swe40006-alerts` |

Dimensioned by ASG rather than instance ID so the alarm survives instance replacement — an
instance-scoped alarm breaks the moment the ASG replaces a member.

This has a consequence for testing: because the metric is an average across the group,
load applied to one instance of two produces roughly 50% group utilisation and never
crosses the threshold. Load must be applied to all instances simultaneously.

The five-minute period is a consequence of basic monitoring; one-minute resolution requires
paid detailed monitoring. Combined with the averaging window, this means an alarm
transition lags the onset of load by roughly eight to twelve minutes.

---

## Conversion notes for Infrastructure as Code

Dependency ordering for a CloudFormation or CDK conversion:

1. Security groups — `alb-sg`, then `web-sg` (references `alb-sg`), then `rds-sg`
   (references `web-sg`)
2. IAM policy → IAM role → instance profile
3. S3 bucket (referenced by the IAM policy ARN)
4. RDS subnet group → RDS instance
5. Target group → Load balancer → Listener
6. Launch template (references AMI, `web-sg`, instance profile)
7. Auto Scaling Group (references launch template, target group, subnets)
8. SNS topic → subscription → CloudWatch alarm (references the ASG name)

The AMI is the one resource not naturally expressible as a template. Either build it with
EC2 Image Builder as a separate pipeline, or replace the golden-AMI approach with
boot-time provisioning from a base AMI and accept the slower boot.
