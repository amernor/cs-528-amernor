## Part 6: server-side timings

Source: `timings.csv`, rows since 2026-10-27T07:05:00 UTC. 100,001 requests (200: 95,414, 400: 4,587).
Measured with `time.perf_counter_ns()` around each step's function. Steps that do not run for a request (no Cloud Storage read for 400/501) are left out of that step's statistics.

### All requests

| Step | Requests | Mean (ms) | Median (ms) | p95 (ms) | p99 (ms) | Max (ms) |
|---|---:|---:|---:|---:|---:|---:|
| (a) process request + extract headers | 100,001 | 0.11 | 0.10 | 0.21 | 0.31 | 4.94 |
| (b) read file from Cloud Storage | 95,414 | 78.25 | 61.14 | 148.22 | 316.00 | 5851.51 |
| (c) send response | 100,001 | 1.33 | 1.31 | 2.78 | 3.87 | 75.29 |
| (d) insert into Cloud SQL | 100,001 | 76.18 | 22.40 | 212.57 | 488.44 | 4795.54 |
| Total of the four steps | 100,001 | 152.28 | 118.13 | 295.66 | 745.76 | 5864.71 |

### Successful requests (200)

| Step | Requests | Mean (ms) | Median (ms) | p95 (ms) | p99 (ms) | Max (ms) |
|---|---:|---:|---:|---:|---:|---:|
| (a) process request + extract headers | 95,414 | 0.11 | 0.10 | 0.21 | 0.31 | 4.94 |
| (b) read file from Cloud Storage | 95,414 | 78.25 | 61.14 | 148.22 | 316.00 | 5851.51 |
| (c) send response | 95,414 | 1.39 | 1.39 | 2.80 | 3.90 | 75.29 |
| (d) insert into Cloud SQL | 95,414 | 76.03 | 22.43 | 212.38 | 488.21 | 4795.54 |
| Total of the four steps | 95,414 | 155.78 | 120.66 | 297.37 | 751.12 | 5864.71 |

### Failed requests (non-200)

| Step | Requests | Mean (ms) | Median (ms) | p95 (ms) | p99 (ms) | Max (ms) |
|---|---:|---:|---:|---:|---:|---:|
| (a) process request + extract headers | 4,587 | 0.11 | 0.10 | 0.21 | 0.32 | 0.76 |
| (b) read file from Cloud Storage | 0 | – | – | – | – | – |
| (c) send response | 4,587 | 0.21 | 0.17 | 0.38 | 0.98 | 3.99 |
| (d) insert into Cloud SQL | 4,587 | 79.20 | 21.51 | 217.21 | 493.73 | 4541.15 |
| Total of the four steps | 4,587 | 79.53 | 21.86 | 217.61 | 494.02 | 4541.39 |
