-- HW5 schema (same DDL as hw5/setup_schema.py). The source tables of the 3NF
-- migration; ensure_data.py creates them if they are missing and restores
-- their data from the bucket snapshot if they are empty.

CREATE TABLE IF NOT EXISTS requests (
  id             BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  received_at    DATETIME(6)  NOT NULL,
  country        VARCHAR(64),
  client_ip      VARCHAR(45),
  gender         VARCHAR(16),
  age            VARCHAR(16),
  income         VARCHAR(32),
  is_banned      BOOLEAN      NOT NULL,
  time_of_day    DATETIME,
  requested_file VARCHAR(512),
  method         VARCHAR(10),
  status_code    SMALLINT     NOT NULL,
  INDEX idx_country (country),
  INDEX idx_status (status_code)
);

CREATE TABLE IF NOT EXISTS failed_requests (
  id              BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  time_of_request DATETIME(6)  NOT NULL,
  requested_file  VARCHAR(512),
  error_code      SMALLINT     NOT NULL
);
