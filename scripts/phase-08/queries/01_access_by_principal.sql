-- Security: who touched the archive, how, and when. Last 7 days.
-- Service agents (replication, KMS) and humans appear side by side.
SELECT
  protopayload_auditlog.authenticationInfo.principalEmail AS principal,
  CASE
    WHEN protopayload_auditlog.authenticationInfo.principalEmail LIKE '%gserviceaccount.com' THEN 'service account'
    ELSE 'human'
  END AS principal_type,
  resource.labels.bucket_name AS bucket,
  protopayload_auditlog.methodName AS method,
  COUNT(*) AS operations,
  MAX(timestamp) AS last_seen
FROM `{project}.{dataset}.cloudaudit_googleapis_com_data_access`
WHERE timestamp > TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 7 DAY)
GROUP BY principal, principal_type, bucket, method
ORDER BY operations DESC
LIMIT 25
