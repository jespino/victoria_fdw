-- Example queries joining shop_ops (demo/shop_ops.sql) with live
-- VictoriaMetrics and VictoriaLogs data from the play servers.
--
--   psql -h localhost -U postgres -d shop_ops -f demo/queries.sql

\timing on
\pset null '·'

\echo '1. CPU used by each service of the shop in the last 15 minutes, with its team'
SELECT t.name AS team, s.name AS service, s.tier,
       round(avg(c.cores)::numeric, 4) AS avg_cores,
       round(max(c.cores)::numeric, 4) AS peak_cores
FROM services s
JOIN teams t ON t.id = s.team_id
JOIN vm.container_cpu c ON c.container = s.name
WHERE c.time > now() - interval '15 minutes'
GROUP BY 1, 2, 3
ORDER BY avg_cores DESC
LIMIT 10;

\echo '2. CPU per team over the last hour vs its budget (share of the shop CPU)'
SELECT t.name AS team,
       round(sum(c.cores)::numeric / count(DISTINCT c.time), 3) AS avg_cores,
       round((100 * sum(c.cores) / sum(sum(c.cores)) OVER ())::numeric, 1) AS cpu_share_pct,
       (SELECT sum(monthly_budget_usd) FROM services WHERE team_id = t.id) AS monthly_budget_usd
FROM teams t
JOIN services s ON s.team_id = t.id
JOIN vm.container_cpu c ON c.container = s.name
WHERE c.time > now() - interval '1 hour'
GROUP BY t.id, t.name
ORDER BY avg_cores DESC;

\echo '3. Host inventory with live CPU utilization and free memory (last 30 minutes)'
SELECT h.hostname, h.instance, h.zone, h.model, t.name AS owner,
       cpu.avg_pct AS cpu_pct, cpu.peak_pct, mem.free_pct AS mem_free_pct,
       h.monthly_cost_usd,
       round(h.monthly_cost_usd / greatest(cpu.avg_pct, 1) , 2) AS usd_per_cpu_pct
FROM hosts h
JOIN teams t ON t.id = h.owner_team_id
JOIN (SELECT instance, round(100 * avg(utilization))::int AS avg_pct, round(100 * max(utilization))::int AS peak_pct
      FROM vm.host_cpu WHERE time > now() - interval '30 minutes' GROUP BY 1) cpu ON cpu.instance = h.instance
JOIN (SELECT instance, round(100 * avg(available_ratio))::int AS free_pct
      FROM vm.host_memory WHERE time > now() - interval '30 minutes' GROUP BY 1) mem ON mem.instance = h.instance
ORDER BY cpu_pct DESC;

\echo '4. Hosts in the inventory that node-exporter did not scrape successfully in the last 5 minutes'
SELECT h.hostname, h.instance, max(u.time) AS last_seen
FROM hosts h
LEFT JOIN vm.up u ON u.instance = h.instance AND u.job = 'node-exporter' AND u.value = 1
                 AND u.time > now() - interval '5 minutes'
GROUP BY 1, 2
HAVING max(u.time) IS NULL;

\echo '5. Log activity around each recent deployment (10 minutes before vs after)'
SELECT d.deployed_at, d.service, d.version, e.name AS deployed_by, d.status,
       before.lines AS lines_before, after.lines AS lines_after
FROM deployments d
JOIN engineers e ON e.id = d.deployed_by
CROSS JOIN LATERAL (SELECT count(*) AS lines FROM vl.shop_logs l
                    WHERE l.container = d.service
                      AND l.time >= d.deployed_at - interval '10 minutes' AND l.time < d.deployed_at) before
CROSS JOIN LATERAL (SELECT count(*) AS lines FROM vl.shop_logs l
                    WHERE l.container = d.service
                      AND l.time >= d.deployed_at AND l.time < d.deployed_at + interval '10 minutes') after
WHERE d.deployed_at > now() - interval '3 hours'
ORDER BY d.deployed_at DESC
LIMIT 10;

\echo '6. Incidents: CPU of the affected service during the incident vs the 30 minutes before'
-- LATERAL sends each incident's own time window to VictoriaMetrics. (A plain
-- join could use a hash join, where conditions referring to the incident
-- can't be pushed down, and the scan would default to the last 3 hours.)
SELECT i.id, i.severity, i.service, i.title, i.started_at,
       coalesce(i.resolved_at, now()) - i.started_at AS duration, c.cores_before, c.cores_during
FROM incidents i
CROSS JOIN LATERAL (
    SELECT round(avg(cores) FILTER (WHERE time < i.started_at)::numeric, 4) AS cores_before,
           round(avg(cores) FILTER (WHERE time >= i.started_at)::numeric, 4) AS cores_during
    FROM vm.container_cpu
    WHERE container = i.service
      AND time >= i.started_at - interval '30 minutes' AND time <= coalesce(i.resolved_at, now())) c
ORDER BY i.started_at DESC;

\echo '7. Who to page: the services logging the most in the last 15 minutes, with the current on-call engineer'
SELECT l.container AS service, count(*) AS log_lines, t.name AS team, e.name AS on_call, t.slack_channel
FROM vl.shop_logs l
JOIN services s ON s.name = l.container
JOIN teams t ON t.id = s.team_id
JOIN oncall_shifts o ON o.team_id = t.id AND now() >= o.starts_at AND now() < o.ends_at
JOIN engineers e ON e.id = o.engineer_id
WHERE l.time > now() - interval '15 minutes'
GROUP BY 1, 3, 4, 5
ORDER BY log_lines DESC
LIMIT 5;

\echo '8. Business vs traffic: orders vs frontend requests, in 30-minute buckets over the last 6 hours'
SELECT b.bucket, b.orders, b.revenue_usd, round(r.req_per_s::numeric, 2) AS frontend_req_per_s,
       round((b.orders / nullif(r.req_per_s * 1800, 0) * 100)::numeric, 3) AS conversion_pct
FROM (SELECT date_bin('30 minutes', created_at, timestamptz '2000-01-01') AS bucket,
             count(*) AS orders, sum(total_usd) AS revenue_usd
      FROM orders WHERE created_at > now() - interval '6 hours' GROUP BY 1) b
JOIN (SELECT date_bin('30 minutes', time, timestamptz '2000-01-01') AS bucket, avg(per_second) AS req_per_s
      FROM (SELECT time, sum(per_second) AS per_second FROM vm.http_requests
            WHERE service = 'frontend' AND time > now() - interval '6 hours' AND step = interval '5 minutes'
            GROUP BY 1) s
      GROUP BY 1) r USING (bucket)
ORDER BY bucket;

\echo '9. SLO check: frontend p99 latency in the last hour vs its SLO'
SELECT s.name, s.slo_p99_ms,
       round(percentile_cont(0.5) WITHIN GROUP (ORDER BY p.ms)) AS median_p99_ms,
       round(max(p.ms)) AS worst_p99_ms,
       round(100.0 * count(*) FILTER (WHERE p.ms > s.slo_p99_ms) / count(*), 1) AS pct_time_over_slo
FROM services s
JOIN vm.http_p99 p ON p.service = s.name
WHERE p.time > now() - interval '1 hour'
GROUP BY s.name, s.slo_p99_ms;

\echo '10. Dashboards stored as data: each panel query is sent to VictoriaMetrics (one request per panel)'
SELECT d.panel, d.unit, round(avg(m.value)::numeric, 3) AS avg, round(max(m.value)::numeric, 3) AS max
FROM dashboards d
JOIN vm.metrics m ON m.query = d.query
WHERE m.time > now() - interval '30 minutes'
GROUP BY 1, 2
ORDER BY 1;

\echo '11. Errors in the logs of the last hour, per team (LogsQL query pushed down)'
SELECT t.name AS team, l.container AS service, count(*) AS errors, max(l.time) AS last_error,
       left(max(l.msg), 80) AS sample
FROM vl.shop_logs l
JOIN services s ON s.name = l.container
JOIN teams t ON t.id = s.team_id
WHERE l.query = 'kubernetes.pod_namespace:="play-otel" AND (error OR exception OR fail*)'
  AND l.time > now() - interval '1 hour'
GROUP BY 1, 2
ORDER BY errors DESC;

\echo '12. Kubernetes nodes: log volume and cost (last 30 minutes)'
SELECT n.name, n.machine_type, n.hourly_cost_usd, count(l.*) AS log_lines,
       count(DISTINCT l.container) AS services_logging
FROM k8s_nodes n
LEFT JOIN vl.shop_logs l ON l.node = n.name AND l.time > now() - interval '30 minutes'
GROUP BY 1, 2, 3
ORDER BY log_lines DESC;

\echo '13. What is sent to VictoriaMetrics: EXPLAIN ANALYZE shows the pushed-down filters and the requests'
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF, BUFFERS OFF)
SELECT s.name, avg(c.cores)
FROM services s JOIN vm.container_cpu c ON c.container = s.name
WHERE s.team_id = 2 AND c.time > now() - interval '15 minutes'
GROUP BY 1;
