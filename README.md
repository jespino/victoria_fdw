# victoria_fdw

A PostgreSQL foreign data wrapper for [VictoriaMetrics](https://docs.victoriametrics.com/)
(MetricsQL) and [VictoriaLogs](https://docs.victoriametrics.com/victorialogs/)
(LogsQL): query metrics and logs with SQL, and join them with each other and
with your tables. Written in Go with [gopgext](../gopgext).

```sql
CREATE EXTENSION victoria_fdw;
CREATE SERVER vm FOREIGN DATA WRAPPER victoria_fdw
    OPTIONS (type 'metrics', url 'https://play.victoriametrics.com/select/0/prometheus');
CREATE SERVER vl FOREIGN DATA WRAPPER victoria_fdw
    OPTIONS (type 'logs', url 'https://play-vmlogs.victoriametrics.com');
IMPORT FOREIGN SCHEMA metrics FROM SERVER vm INTO public;   -- creates table metrics
IMPORT FOREIGN SCHEMA logs FROM SERVER vl INTO public;      -- creates table logs

-- the last 3 hours (no time condition)
SELECT time, labels->>'instance', value FROM metrics WHERE query = 'up{job="node-exporter"}';

SELECT time, msg FROM logs WHERE query = 'error' AND time > now() - interval '15 minutes' LIMIT 20;
```

## Install

Requirements: [gopgext](../gopgext) (and its requirements: Go, TinyGo,
PostgreSQL 14+ server development files), libcurl with its headers
(`curl` on Arch, `libcurl4-openssl-dev` on Debian/Ubuntu), used by
gopgext/http.

```sh
gopgext install -pg-config /path/to/pg_config .   # builds victoria_fdw.so and installs it
```

## Tables

A foreign table reads from VictoriaMetrics or VictoriaLogs depending on the
`type` option of its server (or its own). Columns are matched by name (or
by their `name` option): some names have a meaning, any other column is a
label (metrics) or a field (logs) of that name.

**Metrics** (`type 'metrics'`, `url` = the Prometheus API base, e.g.
`https://vmselect:8481/select/0/prometheus` or `http://victoria-metrics:8428`):

| Column | Type (suggested) | Content |
|--------|------------------|---------|
| `time` | `timestamptz` | sample time |
| `value` | `float8` | sample value |
| `metric` | `text` | metric name (`__name__`) |
| `labels` | `jsonb` | all labels |
| `query` | `text` | the MetricsQL query |
| `step` | `interval` | the query resolution |
| anything else | `text` | the label of that name (`job`, `instance`, ...) |

**Logs** (`type 'logs'`, `url` = the VictoriaLogs base, e.g.
`http://victoria-logs:9428`):

| Column | Type (suggested) | Content |
|--------|------------------|---------|
| `time` | `timestamptz` | `_time` |
| `msg` | `text` | `_msg` |
| `stream` | `text` | `_stream` |
| `fields` | `jsonb` | all fields |
| `query` | `text` | the LogsQL query (`*` by default) |
| anything else | `text` | the field of that name |

```sql
CREATE FOREIGN TABLE http_requests (time timestamptz, value float8, job text, instance text, code text)
    SERVER vm OPTIONS (query 'sum(rate(http_requests_total[5m])) by (job, instance, code)');

CREATE FOREIGN TABLE app_logs (time timestamptz, msg text, level text,
                               pod text OPTIONS (name 'kubernetes.pod_name'))
    SERVER vl OPTIONS (query 'app:="checkout"');
```

## What is sent to VictoriaMetrics/VictoriaLogs

Conditions of the form `column op value` are pushed down, where the value
is a constant, a stable expression (`now() - interval '1 hour'`), a
parameter, or a column of another table in a join:

| Condition | Metrics | Logs |
|-----------|---------|------|
| `time >`, `>=`, `<`, `<=`, `BETWEEN` | `start`, `end` of `/api/v1/query_range` | `start`, `end` |
| `time = x` | an instant query (`/api/v1/query?time=x`) | `start` = `end` = x |
| no lower bound | 3 hours before the upper bound (`default_range`) | same |
| no upper bound | now (statement start) | same |
| `query = '...'` | the MetricsQL query | the LogsQL query |
| `metric = 'm'`, `label = 'v'` | label filters (`extra_filters[]={__name__="m",label="v"}`, or the query itself when there's no query) | `extra_filters` (`"field":="v"`, `_msg:=`, `_stream:{...}`) |
| `step = '1m'` | the resolution (default: range / 300) | — |

**Every condition is also checked by PostgreSQL**, so results are always
correct; pushdown only limits what is fetched. A metrics table needs a
query: a `query` condition, the `query` option, or a `metric`/label
condition. Logs are read as rows are needed, so a `LIMIT` stops the
transfer.

`EXPLAIN` shows the pushed-down conditions; `EXPLAIN ANALYZE` the actual
request(s):

```
Foreign Scan on up_by_job (actual rows=3900.00 loops=1)
  Filter: ((job = 'node-exporter'::text) AND ("time" > (now() - '00:30:00'::interval)))
  Remote Filters: job = 'node-exporter'::text, "time" > (now() - '00:30:00'::interval)
  Remote Request: GET https://play.victoriametrics.com/select/0/prometheus/api/v1/query_range?query=up&start=1795107538.394&end=1795109338.394&step=6&extra_filters[]={job="node-exporter"}
  Remote Requests: 1
```

## Joins

Joins work like with any table. When a join condition can be pushed down,
PostgreSQL can also send one request per row of the other side (a
parameterized nested loop):

```sql
-- queries stored in a table, each sent to VictoriaMetrics
SELECT d.panel, avg(m.value)
FROM dashboards d JOIN metrics m ON m.query = d.q AND m.time > now() - interval '15 minutes'
GROUP BY 1;

-- metrics of the jobs a team owns
SELECT t.team, u.instance, avg(u.value)
FROM teams t JOIN up_by_job u ON u.job = t.job
GROUP BY 1, 2;

-- logs around each incident
SELECT i.id, l.time, l.msg
FROM incidents i,
LATERAL (SELECT * FROM app_logs l WHERE l.time BETWEEN i.at - interval '5 minutes' AND i.at + interval '5 minutes'
         LIMIT 100) l;
```

## Options

| Option | Where | Meaning |
|--------|-------|---------|
| `url` | server (required), table | base URL |
| `type` | server, table | `metrics` or `logs` |
| `query` | table | default query (overridden by a `query` condition) |
| `default_range` | server, table | the range without a lower time bound (default `3 hours`; `90m`, `1 day`...) |
| `step` | server, table | metrics resolution (default: range / 300) |
| `limit` | server, table | logs: maximum entries per request |
| `timeout` | server, table | request timeout in seconds (default 300) |
| `header` | server, table, user mapping | an extra HTTP header, e.g. `Authorization: Bearer ...` |
| `name` | column | the label/field the column reads |

Long requests can be canceled (`statement_timeout`, Ctrl-C) at any time.
Remote errors are raised with SQLSTATE `HV000` and the server's message.

## How it works

It's pure Go (about 840 lines): `main.go` registers the wrapper with
gopgext/fdw (options, which conditions are pushed down, IMPORT FOREIGN
SCHEMA), `request.go` turns the pushed-down conditions into a request
(time range, filters), `metrics.go` and `logs.go` talk to VictoriaMetrics
and VictoriaLogs with gopgext/http and turn responses into rows. The
PostgreSQL side (planning, parameterized paths for joins, evaluating the
pushed-down values when a scan starts or restarts, EXPLAIN) is gopgext/fdw,
and HTTP(S) is libcurl, pulled incrementally so cancellation and `LIMIT`
take effect immediately.

## Demo

`demo/shop_ops.sql` creates an ops/business database for the company
running the OpenTelemetry demo shop that the playgrounds monitor: teams,
engineers, the shop's 22 services (the real `container` /
`kubernetes.container_name` values), the 13 hosts node-exporter scrapes
(real `instance` values), the Kubernetes nodes, on-call shifts,
deployments, incidents, customers, orders and dashboard queries, plus
foreign tables for the shop's metrics and logs. `demo/queries.sql` joins
them: CPU per team, hosts with live utilization, logs around deployments,
incidents, who to page, orders vs traffic, SLOs...

```sh
createdb shop_ops
psql -d shop_ops -f demo/shop_ops.sql     # re-run to refresh the timestamps
psql -d shop_ops -f demo/queries.sql
```

Time conditions that refer to another table (`m.time >= i.started_at`)
are only pushed down when the planner sends them per outer row (a nested
loop). Write such joins with `LATERAL` (see `demo/queries.sql`, query 6):
with a hash join, the scan would use the default range (the last 3 hours).

## Tests

```sh
sh test/run.sh /path/to/pg_config
```

runs `test/fdw.sql` in a throwaway cluster against the public playgrounds
(play.victoriametrics.com and play-vmlogs.victoriametrics.com): time range
defaults and pushdown, instant queries, label/field filters, logs `LIMIT`,
parameterized joins, `LATERAL`, errors and cancellation. Tested with
PostgreSQL 17 and 19.
