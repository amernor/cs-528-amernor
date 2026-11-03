-- HW6: copy the HW5 data (requests, failed_requests) into the 3NF tables.
-- Run after schema_3nf.sql. Idempotent: INSERT IGNORE skips rows that are
-- already there, so re-running adds nothing. migrate_3nf.py runs the checks
-- in precheck_3nf.sql first and refuses to migrate if they fail.

-- 1. countries: one row per distinct country (is_banned is the same for every
--    row of a country - checked in precheck_3nf.sql - so MAX just picks it)
INSERT IGNORE INTO countries (name, is_banned)
SELECT country, MAX(is_banned)
FROM requests
WHERE country IS NOT NULL
GROUP BY country
ORDER BY country;

-- 2. client_ips: one row per distinct IP, pointing to its (single) country
INSERT IGNORE INTO client_ips (client_ip, country_id)
SELECT DISTINCT r.client_ip, c.country_id
FROM requests r
JOIN countries c ON c.name = r.country
WHERE r.client_ip IS NOT NULL;

-- 3. requests_3nf: every request, without country / is_banned
INSERT IGNORE INTO requests_3nf
  (id, received_at, client_ip, gender, age, income, time_of_day,
   requested_file, method, status_code)
SELECT id, received_at, client_ip, gender, age, income, time_of_day,
       requested_file, method, status_code
FROM requests;

-- 4. failed_requests_3nf: link each HW5 failed_requests row to its request.
--    service1 wrote both rows in one transaction with the same timestamp,
--    file and status code, so those three columns identify the request.
--    IGNORE INDEX: otherwise MySQL looks up idx_status once per failed row
--    (~4.6k x 4.6k random row reads, minutes on db-f1-micro when the table
--    is not cached); without it, it hash-joins with one scan of each table.
INSERT IGNORE INTO failed_requests_3nf (request_id)
SELECT r.id
FROM failed_requests f
JOIN requests r IGNORE INDEX (idx_status)
  ON  r.received_at    = f.time_of_request
  AND r.requested_file <=> f.requested_file
  AND r.status_code    = f.error_code;
