-- Run 03_schema.sql and sample_data.sql on an empty database first.
-- The sample writes roll back row changes. Inserted IDs can still advance.
-- These queries use check timestamps stored in UTC.

-- R1  READ   login: find user by email
select u.*
from users u
where u.email = 'demo@kreg.example';

-- R2  READ   register: check if the email is already used
select exists (
    select 1 from users u where u.email = 'new@kreg.example'
) as email_in_use;

-- R3  READ   profile: get the signed-in user
select u.id, u.name, u.email, u.created_at
from users u
where u.id = 1;

-- R4  READ   list the user's monitors, first page
select m.*
from monitors m
where m.user_id = 1
order by m.created_at desc, m.id desc
limit 10 offset 0;

-- R5  READ   count the user's monitors for pagination
select count(*) as total
from monitors m
where m.user_id = 1;

-- R6  READ   get a monitor and check that it belongs to the user
select m.*
from monitors m
where m.id = 1 and m.user_id = 1;

-- R7  READ   latest 50 check results for a monitor the user owns
select c.*
from check_results c
join monitors m on m.id = c.monitor_id
where c.monitor_id = 1 and m.user_id = 1
order by c.checked_at desc, c.id desc
limit 50;

-- R8  READ   check monitor ownership before an update
select m.id
from monitors m
where m.id = 1 and m.user_id = 1;

-- R9  READ   scheduler: load active monitors
select m.*
from monitors m
where m.is_active;

-- R10 READ   scheduler: filter to monitors that are due
-- The scheduler normally does this filter in JavaScript, with one second of slack.
select m.*
from monitors m
where m.is_active
  and (m.last_checked_at is null or m.last_checked_at <=
       (now() at time zone 'UTC') - (m.interval_sec - 1) * interval '1 second');

-- R11 READ   stats for one monitor over the last 24 hours
select count(c.id)::int as "totalChecks24h",
       round(100.0 * count(c.id) filter (where c.is_up)
             / nullif(count(c.id), 0), 2)::float as "uptime24h",
       round(avg(c.response_time_ms) filter (where c.is_up))::int as "avgMs24h"
from monitors m
left join check_results c on c.monitor_id = m.id
  and c.checked_at >= (now() at time zone 'UTC') - interval '24 hours'
where m.id = 1
group by m.id;

-- R12 READ   daily uptime for one monitor, up to seven days
with recent as (
    select c.checked_at::date as day,
           count(*)::int as checks,
           round(100.0 * count(*) filter (where c.is_up) / count(*), 2)::float as "uptimePct"
    from check_results c
    where c.monitor_id = 1
      and c.checked_at >= (now() at time zone 'UTC') - interval '7 days'
    group by c.checked_at::date
    order by c.checked_at::date desc
    limit 7
)
select to_char(r.day, 'YYYY-MM-DD') as day, r.checks, r."uptimePct"
from recent r
order by r.day;

-- R13 READ   health check: see if the database responds
select 1;


-- From the app repo's docs/queries.sql, using the current column names.

-- R14 READ   uptime and average response time per monitor, last 24 hours
select c.monitor_id, count(*) as total_checks,
       count(*) filter (where c.is_up) as successful_checks,
       round(100.0 * count(*) filter (where c.is_up) / count(*), 2) as uptime_pct,
       round(avg(c.response_time_ms) filter (where c.is_up), 1) as avg_response_ms
from check_results c
where c.checked_at >= (now() at time zone 'UTC') - interval '24 hours'
group by c.monitor_id
order by c.monitor_id;

-- R15 READ   daily UTC uptime per monitor across all stored checks
select c.monitor_id, c.checked_at::date as day, count(*) as total_checks,
       count(*) filter (where c.is_up) as successful_checks,
       round(100.0 * count(*) filter (where c.is_up) / count(*), 2) as uptime_pct
from check_results c
group by c.monitor_id, c.checked_at::date
order by c.monitor_id, day;


-- Extra SQL examples for monitor views in the project.

-- R16 READ   show the user's monitors with their latest check, if any
select m.*, c.checked_at, c.is_up, c.status_code, c.response_time_ms, c.error
from monitors m
left join lateral (
    select c.checked_at, c.is_up, c.status_code, c.response_time_ms, c.error
    from check_results c
    where c.monitor_id = m.id
    order by c.checked_at desc, c.id desc
    limit 1
) c on true
where m.user_id = 1
order by m.created_at desc, m.id desc
limit 10 offset 0;

-- R17 READ   incident history with the monitor name, newest first
select i.*, m.name as monitor_name
from incidents i
join monitors m on m.id = i.monitor_id
where m.id = 3 and m.user_id = 1
order by i.started_at desc, i.id desc;

-- R18 READ   one owner's public status page with uptime and response time
select m.id, m.name, m.status,
       round(100.0 * count(c.id) filter (where c.is_up)
             / nullif(count(c.id), 0), 2)::float as "uptime24h",
       round(avg(c.response_time_ms) filter (where c.is_up))::int as "avgMs24h"
from users u
join monitors m on m.user_id = u.id
left join check_results c on c.monitor_id = m.id
  and c.checked_at >= (now() at time zone 'UTC') - interval '24 hours'
where u.id = 1 and m.is_public
group by m.id
order by m.id;


begin;

-- W1  WRITE  register a new user
insert into users (name, email, password_hash)
values ('New User', 'new@kreg.example', 'example-password-hash')
returning id, name, email, created_at;

-- W2  WRITE  add a monitor
insert into monitors (user_id, name, url, interval_sec, is_public)
values (1, 'Docs site', 'https://docs.example.com', 60, false)
returning *;

-- W3  WRITE  edit a monitor's settings
update monitors m
set name = 'Home page v2', url = 'https://www.example.com',
    interval_sec = 90, is_public = true
where m.id = 1 and m.user_id = 1
returning m.*;

-- W4  WRITE  delete a monitor and cascade to its checks and incidents
delete from monitors m
where m.id = 4 and m.user_id = 1;

-- W5  WRITE  save a failed check (the app runs W5 and W6 together)
insert into check_results (monitor_id, is_up, status_code, response_time_ms, error, checked_at)
values (2, false, 503, 125, 'HTTP 503', now() at time zone 'UTC')
returning *;

-- W6  WRITE  save last check time, failure count and status
-- This sample check is the third failure in a row.
update monitors m
set last_checked_at = now() at time zone 'UTC',
    consecutive_failures = 3, status = 'DOWN'
where m.id = 2
returning m.*;

-- W7  WRITE  open an incident when a monitor goes down
insert into incidents (monitor_id, reason, started_at)
values (2, 'HTTP 503', now() at time zone 'UTC')
returning *;

-- W8  WRITE  close open incidents after a successful check sets the monitor UP
-- The app emits a recovery event at that point. The sample monitor is already UP.
update incidents i
set resolved_at = m.last_checked_at
from monitors m
where m.id = 3 and m.id = i.monitor_id and m.status = 'UP'
  and i.resolved_at is null and m.last_checked_at >= i.started_at
returning i.*;

rollback;
