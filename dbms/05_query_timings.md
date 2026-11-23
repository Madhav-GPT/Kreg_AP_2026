# Query timings for the Kreg Lite app

All the queries from `dbms/04_queries.sql` were timed on PostgreSQL 18.6, on a fresh database made with `dbms/03_schema.sql` and filled with `dbms/sample_data.sql` (3 users, 10 monitors, 3825 check results, 3 incidents), then `ANALYZE`.
Every query was run 3 times with `EXPLAIN (ANALYZE, BUFFERS)` and the table shows the 3 `Execution Time` values and their average. Write queries ran inside `BEGIN ... ROLLBACK` so the data stays the same for every run.
The full output of all 3 runs of each query is in [`dbms/plans/`](plans/) (one file per query, e.g. `plans/R1.txt`).

| Query | Type | What it does | Run 1 (ms) | Run 2 (ms) | Run 3 (ms) | Average (ms) | Scan type |
|-------|------|--------------|-----------:|-----------:|-----------:|-------------:|-----------|
| R1 | READ | login: find user by email | 0.023 | 0.021 | 0.019 | 0.021 | Seq Scan on users |
| R2 | READ | register: check if the email is already used | 0.019 | 0.019 | 0.020 | 0.019 | Seq Scan on users |
| R3 | READ | profile: get the signed-in user | 0.020 | 0.018 | 0.021 | 0.020 | Seq Scan on users |
| R4 | READ | list the user's monitors, first page | 0.029 | 0.031 | 0.031 | 0.030 | Seq Scan on monitors |
| R5 | READ | count the user's monitors for pagination | 0.034 | 0.035 | 0.031 | 0.033 | Seq Scan on monitors |
| R6 | READ | get a monitor and check that it belongs to the user | 0.029 | 0.023 | 0.024 | 0.025 | Seq Scan on monitors |
| R7 | READ | latest 50 check results for a monitor the user owns | 0.069 | 0.059 | 0.060 | 0.063 | Index Scan using check_results_monitor_id_checked_at_idx on check_results<br>Seq Scan on monitors |
| R8 | READ | check monitor ownership before an update | 0.020 | 0.019 | 0.021 | 0.020 | Seq Scan on monitors |
| R9 | READ | scheduler: load active monitors | 0.025 | 0.022 | 0.023 | 0.023 | Seq Scan on monitors |
| R10 | READ | scheduler: filter to monitors that are due | 0.028 | 0.029 | 0.026 | 0.028 | Seq Scan on monitors |
| R11 | READ | stats for one monitor over the last 24 hours | 0.584 | 0.057 | 0.056 | 0.232 | Seq Scan on monitors<br>Bitmap Heap Scan on check_results<br>Bitmap Index Scan on check_results_monitor_id_checked_at_idx |
| R12 | READ | daily uptime for one monitor, up to seven days | 1.929 | 1.531 | 1.577 | 1.679 | Bitmap Heap Scan on check_results<br>Bitmap Index Scan on check_results_monitor_id_checked_at_idx |
| R13 | READ | health check: see if the database responds | 0.014 | 0.014 | 0.029 | 0.019 | — |
| R14 | READ | uptime and average response time per monitor, last 24 hours | 0.176 | 0.165 | 0.140 | 0.160 | Bitmap Heap Scan on check_results<br>Bitmap Index Scan on check_results_monitor_id_checked_at_idx |
| R15 | READ | daily UTC uptime per monitor across all stored checks | 1.276 | 1.262 | 1.372 | 1.303 | Seq Scan on check_results |
| R16 | READ | show the user's monitors with their latest check, if any | 0.125 | 0.160 | 0.072 | 0.119 | Seq Scan on monitors<br>Index Scan using check_results_monitor_id_checked_at_idx on check_results |
| R17 | READ | incident history with the monitor name, newest first | 0.058 | 0.076 | 0.070 | 0.068 | Seq Scan on monitors<br>Seq Scan on incidents |
| R18 | READ | one owner's public status page with uptime and response time | 0.170 | 0.166 | 0.159 | 0.165 | Seq Scan on users<br>Bitmap Heap Scan on check_results<br>Bitmap Index Scan on check_results_monitor_id_checked_at_idx<br>Seq Scan on monitors |
| W1 | WRITE | register a new user | 0.121 | 0.109 | 0.104 | 0.111 | — |
| W2 | WRITE | add a monitor | 0.380 | 0.332 | 0.355 | 0.356 | — |
| W3 | WRITE | edit a monitor's settings | 0.116 | 0.089 | 0.101 | 0.102 | Seq Scan on monitors |
| W4 | WRITE | delete a monitor and cascade to its checks and incidents | 0.436 | 0.501 | 0.436 | 0.458 | Seq Scan on monitors |
| W5 | WRITE | save a failed check (the app runs W5 and W6 together) | 0.455 | 0.677 | 0.464 | 0.532 | — |
| W6 | WRITE | save last check time, failure count and status | 0.101 | 0.182 | 0.106 | 0.130 | Seq Scan on monitors |
| W7 | WRITE | open an incident when a monitor goes down | 0.431 | 0.496 | 0.336 | 0.421 | — |
| W8 | WRITE | close open incidents after a successful check sets the monitor UP | 0.094 | 0.103 | 0.092 | 0.096 | Seq Scan on incidents<br>Seq Scan on monitors |
| **Total** | | | 6.762 | 6.196 | 5.745 | 6.234 | |

Some notes:

- 19 of 26 queries show a Seq Scan. The tables are tiny here (3 users, 10 monitors), so reading the whole table is cheaper than using an index and the planner picks the seq scan even where an index exists (like `users_email_key` for R1/R2).
- 6 queries use an index, mostly on `check_results` (3825 rows), where the `(monitor_id, checked_at)` index pays off for one monitor's recent checks.
- The slowest ones are R12 (1.679 ms), R15 (1.303 ms), W5 (0.532 ms). They group check results by day or by monitor, so they read many check rows.
- Every query is under 2 ms on this data. With a lot more check results the uptime reports (R11, R12, R14, R15, R18) would grow first, because they read check history.
- Run 1 is sometimes slower than runs 2 and 3, because the first run has to read the pages into memory.
