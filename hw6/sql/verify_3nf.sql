-- HW6: checks after the migration. Every query must return 0.

-- every HW5 request made it into requests_3nf
SELECT (SELECT COUNT(*) FROM requests) - (SELECT COUNT(*) FROM requests_3nf)
  AS missing_requests;

-- joining the 3NF tables back together gives exactly the HW5 rows
SELECT COUNT(*) AS rows_that_differ
FROM requests r
JOIN requests_3nf n ON n.id = r.id
LEFT JOIN client_ips ip ON ip.client_ip = n.client_ip
LEFT JOIN countries c   ON c.country_id = ip.country_id
WHERE NOT (r.country <=> c.name
       AND r.is_banned = COALESCE(c.is_banned, FALSE)
       AND r.client_ip <=> n.client_ip
       AND r.received_at = n.received_at
       AND r.gender <=> n.gender AND r.age <=> n.age AND r.income <=> n.income
       AND r.time_of_day <=> n.time_of_day
       AND r.requested_file <=> n.requested_file
       AND r.method <=> n.method AND r.status_code = n.status_code);

-- every HW5 failed_requests row was linked to exactly one request
SELECT (SELECT COUNT(*) FROM failed_requests) - (SELECT COUNT(*) FROM failed_requests_3nf)
  AS unlinked_failed_requests;

-- failed_requests_3nf holds exactly the non-200 requests
SELECT COUNT(*) AS failed_mismatch FROM (
  SELECT id FROM requests_3nf n
  WHERE n.status_code <> 200
    AND id NOT IN (SELECT request_id FROM failed_requests_3nf)
  UNION ALL
  SELECT request_id FROM failed_requests_3nf f
  JOIN requests_3nf n ON n.id = f.request_id WHERE n.status_code = 200) t;
