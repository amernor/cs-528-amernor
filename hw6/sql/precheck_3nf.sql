-- HW6: checks on the HW5 data that the 3NF design relies on. Every query
-- must return 0; migrate_3nf.py stops before migrating if one does not.

-- client_ip -> country: no IP is seen with two different countries
SELECT COUNT(*) AS ips_with_several_countries FROM (
  SELECT client_ip FROM requests WHERE client_ip IS NOT NULL
  GROUP BY client_ip HAVING COUNT(DISTINCT country) > 1) t;

-- country -> is_banned: no country is both banned and not banned
SELECT COUNT(*) AS countries_with_several_banned_flags FROM (
  SELECT country FROM requests WHERE country IS NOT NULL
  GROUP BY country HAVING COUNT(DISTINCT is_banned) > 1) t;

-- a country is only reachable through an IP, so no row may have a country
-- without an IP (or an IP without a country)
SELECT COUNT(*) AS rows_with_country_xor_ip
FROM requests WHERE (country IS NULL) <> (client_ip IS NULL);

-- requests without a country (scanners) must not be marked banned, since
-- their banned flag is no longer stored
SELECT COUNT(*) AS banned_rows_without_country
FROM requests WHERE country IS NULL AND is_banned;
