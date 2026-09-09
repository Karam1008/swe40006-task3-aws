# Decommissioning Procedure

Ordered teardown for the SWE40006 Task 3 deployment. **Run only after grading is
complete.** The ordering matters: AWS refuses deletion of resources still referenced by
others, so dependencies come out before the resources they depend on.

Before starting, confirm every screenshot is already embedded in the submitted report.
Once the stack is gone it cannot be revisited for a missing capture.

## Order

1. **Auto Scaling Group** — set desired and minimum capacity to `0`, wait for instances to
   terminate, then delete `swe40006-asg`. Deleting the group while instances are running
   leaves orphaned instances behind.
2. **Load balancer** — delete `swe40006-alb`. This is the largest recurring cost item, so
   do it first if you are short of time.
3. **Target group** — delete `swe40006-tg`. It cannot be deleted while the listener
   references it.
4. **RDS** — delete `swe40006-rds`. Disable deletion protection first if it was enabled.
   Decline the final snapshot, or snapshot storage continues to bill.
5. **RDS automated backups** — check the *Automated backups* tab and delete any retained
   entries. These survive instance deletion.
6. **EC2 instances** — terminate `SWE40006-WebServer-Pass` and
   `SWE40006-WebServer-Restore`.
7. **EBS volumes and snapshots** — delete volumes left in the `available` state, and the
   snapshot created when the AMI was built. Neither is removed automatically.
8. **AMI** — deregister `swe40006-wordpress-ami`.
9. **Launch template** — delete `swe40006-launch-template`.
10. **S3** — empty the bucket first, including previous object versions, then delete it.
    Versioning is enabled, so a bucket that looks empty may still hold versioned objects
    and delete markers.
11. **CloudWatch** — delete `swe40006-high-cpu-alarm` and any dashboard.
12. **SNS** — delete `swe40006-alerts`; this removes its subscriptions.
13. **Security groups** — delete `swe40006-rds-sg`, `swe40006-web-sg`, `swe40006-alb-sg`
    and `launch-wizard-1`. Last, because they only delete once nothing references them.
14. **IAM** — delete the role `swe40006-ec2-s3-role` and the policy
    `swe40006-s3-backup-policy`.
15. **Key pair** — delete `swe40006-pass-key`.

## Verification

Check AWS Billing the following day and confirm recurring charges have stopped. Leave the
budget alert in place as a safety net against anything missed.

## Approximate running cost

Recorded for reference. Rates are ap-southeast-2 on-demand and were current at the time of
the deployment.

| Resource | Approximate monthly |
|---|---|
| Application Load Balancer | ~$16 |
| 2 × `t3.micro` (ASG) | ~$19 |
| `db.t4g.micro` + 20 GiB gp3 | ~$14 |
| S3 storage (~38 MB) | negligible |
| CloudWatch, SNS, Systems Manager | negligible at this volume |

The load balancer bills hourly whether or not traffic flows, which makes it the item worth
deleting first.

Note that `t3` instances default to **unlimited** CPU credit mode. The synthetic load test
used to trigger the CloudWatch alarm drives CPU to 100%, which accrues a surcharge beyond
the baseline if sustained. Keep such tests to minutes rather than hours.
