-- HW6: third-normal-form schema for the HW5 request log.
--
-- The HW5 table `requests` had two transitive dependencies:
--   id -> client_ip -> country      (an IP always comes from the same country)
--   id -> country   -> is_banned    (banned status is a property of the country)
-- and `failed_requests` copied the time / file / status of rows that are
-- already in `requests`, with no key linking the two.
--
-- New tables (the HW5 tables are kept untouched as the migration source):
--   countries            one row per country, with its banned flag
--   client_ips           one row per IP, pointing to its country
--   requests_3nf         one row per request; country/is_banned now come
--                        from client_ips -> countries
--   failed_requests_3nf  the ids of the requests that failed; their time,
--                        file and error code live only in requests_3nf
--
-- gender, age and income stay in requests_3nf: the data shows they are NOT
-- determined by the IP (the same IP is seen with different values), so they
-- are facts about the request, not about the client IP.

CREATE TABLE IF NOT EXISTS countries (
  country_id  SMALLINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  name        VARCHAR(64) NOT NULL,
  is_banned   BOOLEAN     NOT NULL,
  UNIQUE KEY uq_country_name (name)
);

CREATE TABLE IF NOT EXISTS client_ips (
  client_ip   VARCHAR(45)       PRIMARY KEY,
  country_id  SMALLINT UNSIGNED NOT NULL,
  CONSTRAINT fk_ip_country FOREIGN KEY (country_id) REFERENCES countries (country_id)
);

CREATE TABLE IF NOT EXISTS requests_3nf (
  id              BIGINT UNSIGNED PRIMARY KEY,   -- same id as in HW5 `requests`
  received_at     DATETIME(6)  NOT NULL,
  client_ip       VARCHAR(45),                   -- NULL for scanners that send no headers
  gender          VARCHAR(16),
  age             VARCHAR(16),
  income          VARCHAR(32),
  time_of_day     DATETIME,
  requested_file  VARCHAR(512),
  method          VARCHAR(10),
  status_code     SMALLINT     NOT NULL,
  CONSTRAINT fk_req_ip FOREIGN KEY (client_ip) REFERENCES client_ips (client_ip),
  INDEX idx_status (status_code)
);

CREATE TABLE IF NOT EXISTS failed_requests_3nf (
  request_id  BIGINT UNSIGNED PRIMARY KEY,
  CONSTRAINT fk_failed_req FOREIGN KEY (request_id) REFERENCES requests_3nf (id)
);
