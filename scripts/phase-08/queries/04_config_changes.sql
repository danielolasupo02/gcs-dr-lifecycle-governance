-- Security: bucket and IAM configuration changes (Admin Activity logs). Last 30 days.
-- Includes Terraform applies and any manual console edit, such as the Phase 7 drift drill.
SELECT
  timestamp,
  protopayload_auditlog.authenticationInfo.principalEmail AS principal,
  protopayload_auditlog.methodName AS method,
  resource.labels.bucket_name AS bucket,
  protopayload_auditlog.status.code AS status_code
FROM `{project}.{dataset}.cloudaudit_googleapis_com_activity`
WHERE timestamp > TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 30 DAY)
ORDER BY timestamp DESC
LIMIT 20
