-- Sample rows for 04_queries.sql. Load once after 03_schema.sql in a fresh DB.
-- The password hashes are dummy values. These accounts are for SQL examples.

begin;

-- Keep the IDs used in the query examples, even if a previous load failed.
insert into users (id, name, email, password_hash) values
    (1, 'Demo', 'demo@kreg.example', 'example-password-hash'),
    (2, 'Second User', 'second@kreg.example', 'example-password-hash'),
    (3, 'Third User', 'third@kreg.example', 'example-password-hash');
alter sequence users_id_seq restart with 4;

insert into monitors (id, user_id, name, url, interval_sec, is_active, is_public,
                      status, consecutive_failures, last_checked_at, created_at)
select s.id, s.user_id, s.name, 'https://example.com/' || s.id, s.interval_sec,
       s.is_active, s.is_public, s.status::"MonitorStatus", s.failures,
       (now() at time zone 'UTC') - s.seconds_ago * interval '1 second',
       (now() at time zone 'UTC') - interval '10 days' + s.id * interval '1 minute'
from (values
    (1,  1, 'Home page',     60,  true,  true,  'UP',      0, 5),
    (2,  1, 'API',          60,  true,  true,  'UP',      2, 75),
    (3,  1, 'Uploads',      60,  true,  true,  'UP',      0, 90),
    (4,  1, 'Old dashboard', 90,  true,  false, 'UP',      0, 100),
    (5,  1, 'Admin',        120, true,  false, 'UP',      0, 20),
    (6,  1, 'New endpoint', 60,  true,  true,  'UNKNOWN', 0, null),
    (7,  2, 'Store',        30,  true,  true,  'UP',      0, 10),
    (8,  2, 'Payments',     60,  true,  false, 'UP',      0, 100),
    (9,  3, 'Landing page', 30,  true,  true,  'UP',      0, 45),
    (10, 3, 'Archive',      60,  false, false, 'UP',      0, 3600)
) s(id, user_id, name, interval_sec, is_active, is_public, status, failures, seconds_ago)
order by s.id;
alter sequence monitors_id_seq restart with 11;

-- Give each checked monitor 425 results over a little more than a week.
with checks as (
    select m.id as monitor_id,
           m.last_checked_at - (g.n - 1) * interval '30 minutes' as checked_at,
           g.n > m.consecutive_failures and (g.n < 6 or g.n % 19 <> 0)
             and not (m.id = 3 and g.n between 2 and 5)
             and not (m.id = 3 and g.n between 145 and 147)
             and not (m.id = 4 and g.n between 97 and 99) as is_up,
           g.n
    from monitors m
    cross join generate_series(1, 425) g(n)
    where m.last_checked_at is not null
)
insert into check_results (monitor_id, is_up, status_code, response_time_ms, error, checked_at)
select monitor_id, is_up, case when is_up then 200 else 503 end,
       25 + (monitor_id * n) % 190,
       case when not is_up then 'HTTP 503' end, checked_at
from checks;

-- Start at the third failed check and close at the next successful check.
-- Leave one incident open for the recovery example in 04_queries.sql.
insert into incidents (monitor_id, reason, started_at, resolved_at)
select m.id, 'HTTP 503', m.last_checked_at - i.started_ago,
       m.last_checked_at - i.resolved_ago
from monitors m
join (values
    (3, interval '72 hours', interval '71 hours 30 minutes'),
    (4, interval '48 hours', interval '47 hours 30 minutes'),
    (3, interval '1 hour', null)
) i(monitor_id, started_ago, resolved_ago) on i.monitor_id = m.id;

commit;
