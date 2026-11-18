-- Security: requests the archive refused (non-zero status). Last 7 days.
-- Code 7 is PERMISSION_DENIED.
SELECT
  timestamp,
  protopayload_auditlog.authenticationInfo.principalEmail AS principal,
  protopayload_auditlog.methodName AS method,
  REGEXP_EXTRACT(protopayload_auditlog.resourceName, r'objects/(.*)$') AS object,
  resource.labels.bucket_name AS bucket,
  protopayload_auditlog.status.code AS status_code,
  protopayload_auditlog.status.message AS status_message
FROM `{project}.{dataset}.cloudaudit_googleapis_com_data_access`
WHERE timestamp > TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 7 DAY)
  AND protopayload_auditlog.status.code IS NOT NULL
  AND protopayload_auditlog.status.code != 0
ORDER BY timestamp DESC
LIMIT 25
