## Part 7: request statistics

### How many requests were processed successfully vs unsuccessfully?

```sql
SELECT IF(status_code = 200, 'successful (200)', 'unsuccessful (non-200)') AS outcome, COUNT(*) AS requests FROM requests WHERE country IS NOT NULL AND client_ip IS NOT NULL AND gender IS NOT NULL AND age IS NOT NULL AND income IS NOT NULL AND time_of_day IS NOT NULL GROUP BY outcome ORDER BY outcome
```

| outcome | requests |
|---|---|
| successful (200) | 95,413 |
| unsuccessful (non-200) | 4,587 |

### Breakdown of the unsuccessful requests by status code

```sql
SELECT status_code, COUNT(*) AS requests FROM requests WHERE country IS NOT NULL AND client_ip IS NOT NULL AND gender IS NOT NULL AND age IS NOT NULL AND income IS NOT NULL AND time_of_day IS NOT NULL AND status_code <> 200 GROUP BY status_code ORDER BY status_code
```

| status_code | requests |
|---|---|
| 400 | 4,587 |

### How many requests came from banned countries?

```sql
SELECT COUNT(*) AS requests FROM requests WHERE country IS NOT NULL AND client_ip IS NOT NULL AND gender IS NOT NULL AND age IS NOT NULL AND income IS NOT NULL AND time_of_day IS NOT NULL AND is_banned
```

| requests |
|---|
| 4,587 |

### How many requests were made by Male vs Female users?

```sql
SELECT gender, COUNT(*) AS requests FROM requests WHERE country IS NOT NULL AND client_ip IS NOT NULL AND gender IS NOT NULL AND age IS NOT NULL AND income IS NOT NULL AND time_of_day IS NOT NULL GROUP BY gender ORDER BY requests DESC
```

| gender | requests |
|---|---|
| Female | 50,144 |
| Male | 49,856 |

### What were the top 5 countries sending requests?

```sql
SELECT country, COUNT(*) AS requests FROM requests WHERE country IS NOT NULL AND client_ip IS NOT NULL AND gender IS NOT NULL AND age IS NOT NULL AND income IS NOT NULL AND time_of_day IS NOT NULL GROUP BY country ORDER BY requests DESC, country LIMIT 5
```

| country | requests |
|---|---|
| Ghana | 566 |
| Netherlands | 564 |
| Brazil | 563 |
| Croatia | 557 |
| Togo | 554 |

### What age group issued the most requests?

```sql
SELECT age, COUNT(*) AS requests FROM requests WHERE country IS NOT NULL AND client_ip IS NOT NULL AND gender IS NOT NULL AND age IS NOT NULL AND income IS NOT NULL AND time_of_day IS NOT NULL GROUP BY age ORDER BY requests DESC, age LIMIT 3
```

| age | requests |
|---|---|
| 46-55 | 12,699 |
| 26-35 | 12,604 |
| 36-45 | 12,540 |

### What income group issued the most requests?

```sql
SELECT income, COUNT(*) AS requests FROM requests WHERE country IS NOT NULL AND client_ip IS NOT NULL AND gender IS NOT NULL AND age IS NOT NULL AND income IS NOT NULL AND time_of_day IS NOT NULL GROUP BY income ORDER BY requests DESC, income LIMIT 3
```

| income | requests |
|---|---|
| 60k-100k | 12,632 |
| 10k-20k | 12,612 |
| 40k-60k | 12,558 |

### Sanity checks

- Client requests (all six headers present; used above): **100,000**
- Requests without client headers (internet scanners; excluded above): **1**
- Total rows in requests: **100,001**
- Rows in failed_requests: **4,587**
- Non-200 rows in requests (should equal the line above): **4,587**
- First / last request (UTC): 2026-10-27 07:05:05.155501  /  2026-10-27 08:17:19.981009
