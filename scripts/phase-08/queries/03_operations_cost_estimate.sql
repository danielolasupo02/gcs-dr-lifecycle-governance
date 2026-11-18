-- Cost: successful operations per bucket split into Class A (writes, lists) and Class B
-- (reads), priced at approximate Standard-class list prices per 10,000 operations.
-- An estimate from audit logs, not a bill: Nearline and Coldline operations cost more,
-- and storage, retrieval and network charges are not included. Last 30 days.
WITH ops AS (
  SELECT
    resource.labels.bucket_name AS bucket,
    CASE
      WHEN protopayload_auditlog.methodName IN (
        'storage.objects.create', 'storage.objects.list', 'storage.objects.update',
        'storage.objects.patch', 'storage.objects.rewrite', 'storage.objects.copy',
        'storage.objects.compose', 'storage.buckets.list'
      ) THEN 'A'
      ELSE 'B'
    END AS op_class
  FROM `{project}.{dataset}.cloudaudit_googleapis_com_data_access`
  WHERE timestamp > TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 30 DAY)
    AND (protopayload_auditlog.status.code IS NULL OR protopayload_auditlog.status.code = 0)
)
SELECT
  bucket,
  COUNTIF(op_class = 'A') AS class_a_ops,
  COUNTIF(op_class = 'B') AS class_b_ops,
  ROUND(COUNTIF(op_class = 'A') / 10000 * 0.05 + COUNTIF(op_class = 'B') / 10000 * 0.004, 6) AS est_operations_usd
FROM ops
GROUP BY bucket
ORDER BY bucket
