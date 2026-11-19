-- victoria_fdw against the public playgrounds. The data is live, so checks
-- are about invariants and the requests sent (EXPLAIN ANALYZE), not values.
SET client_min_messages = warning;
CREATE EXTENSION victoria_fdw;
CREATE SERVER vm FOREIGN DATA WRAPPER victoria_fdw
	OPTIONS (type 'metrics', url 'https://play.victoriametrics.com/select/0/prometheus');
CREATE SERVER vl FOREIGN DATA WRAPPER victoria_fdw
	OPTIONS (type 'logs', url 'https://play-vmlogs.victoriametrics.com');
IMPORT FOREIGN SCHEMA metrics FROM SERVER vm INTO public;
IMPORT FOREIGN SCHEMA logs FROM SERVER vl INTO public;
CREATE FOREIGN TABLE up_by_job (time timestamptz, value float8, job text, instance text, query text)
	SERVER vm OPTIONS (query 'up');
CREATE FOREIGN TABLE grafana_logs (time timestamptz, msg text, container text OPTIONS (name 'kubernetes.container_name'))
	SERVER vl;

-- The remote request(s) of a query, from EXPLAIN ANALYZE.
CREATE FUNCTION remote(q text, what text DEFAULT 'Remote Request') RETURNS text AS $$
DECLARE
	plan json;
BEGIN
	EXECUTE 'EXPLAIN (ANALYZE, FORMAT JSON, COSTS OFF, TIMING OFF, SUMMARY OFF) ' || q INTO plan;
	RETURN jsonb_path_query_first(plan::jsonb, ('strict $.**."' || what || '"')::jsonpath) #>> '{}';
END $$ LANGUAGE plpgsql;

-- The error of a query, as SQLSTATE: message.
CREATE FUNCTION err(q text) RETURNS text AS $$
BEGIN
	EXECUTE q;
	RETURN 'no error';
EXCEPTION WHEN OTHERS THEN
	RETURN SQLSTATE || ': ' || SQLERRM;
END $$ LANGUAGE plpgsql;

DO $$
DECLARE
	r record;
	req text;
BEGIN
	-- Without time conditions: the last 3 hours.
	SELECT count(*) AS n, max(time) - min(time) AS span, max(time) AS last INTO r
	FROM metrics WHERE query = 'sum(up)';
	ASSERT r.n BETWEEN 250 AND 310, r.n;
	ASSERT r.span BETWEEN interval '2 hours 55 minutes' AND interval '3 hours', r.span;
	ASSERT r.last > now() - interval '2 minutes', r.last;

	-- Time ranges and step from conditions, including stable expressions.
	SELECT count(*) AS n, min(time) AS first, bool_and(step = interval '1 minute') AS step INTO r
	FROM metrics WHERE query = 'sum(up)' AND time >= now() - interval '10 minutes' AND step = '1 minute';
	ASSERT r.n BETWEEN 9 AND 11 AND r.step, r;
	ASSERT r.first >= now() - interval '10 minutes', r.first;
	req := remote($q$SELECT * FROM metrics WHERE query = 'sum(up)' AND time BETWEEN '2026-01-01 00:00:00+00' AND '2026-01-01 01:00:00+00'$q$);
	ASSERT req LIKE '%query_range?query=sum(up)&start=1767225600.000&end=1767229200.000&step=12', req;
	-- Only an upper bound: 3 hours before it.
	req := remote($q$SELECT * FROM metrics WHERE query = 'up' AND time < '2026-01-01 03:00:00+00'$q$);
	ASSERT req LIKE '%start=1767225600.000&end=1767236400.000%', req;

	-- time = x is an instant query.
	req := remote($q$SELECT * FROM metrics WHERE query = 'count(up)' AND time = date_trunc('minute', now()) - interval '5 minutes'$q$);
	ASSERT req LIKE '%/api/v1/query?query=count(up)&time=%', req;
	ASSERT (SELECT count(*) FROM metrics WHERE query = 'count(up)' AND time = date_trunc('minute', now()) - interval '5 minutes') = 1;

	-- Label columns and the metric column become label filters.
	req := remote($q$SELECT * FROM up_by_job WHERE job = 'node-exporter' AND time > now() - interval '5 minutes'$q$);
	ASSERT req LIKE '%query=up&%&extra_filters[]={job="node-exporter"}', req;
	SELECT count(*) AS n, bool_and(job = 'node-exporter') AS ok, count(DISTINCT instance) AS instances INTO r
	FROM up_by_job WHERE job = 'node-exporter' AND time > now() - interval '5 minutes';
	ASSERT r.n > 0 AND r.ok AND r.instances > 1, r;
	req := remote($q$SELECT * FROM metrics WHERE metric = 'up' AND time > now() - interval '5 minutes'$q$);
	ASSERT req LIKE '%query={__name__="up"}&%', req;
	SELECT count(*) AS n, bool_and(labels ->> '__name__' = 'up' AND metric = 'up' AND query = '{__name__="up"}') AS ok INTO r
	FROM metrics WHERE metric = 'up' AND time > now() - interval '5 minutes';
	ASSERT r.n > 0 AND r.ok, r;

	-- Conditions that can't match: no request at all (PostgreSQL or the FDW
	-- sees it).
	ASSERT coalesce(remote($q$SELECT * FROM metrics WHERE query = 'up' AND query = 'down'$q$), 'none') LIKE 'none%';
	ASSERT coalesce(remote($q$SELECT * FROM metrics WHERE query = NULL::text$q$), 'none') LIKE 'none%';
	ASSERT (SELECT count(*) FROM metrics WHERE query = 'up' AND query = (SELECT 'down')) = 0;
	ASSERT (SELECT count(*) FROM metrics WHERE query = 'up' AND time > now() + interval '1 day') = 0;

	-- Logs: fields, field filters, LIMIT (stops reading).
	SELECT count(*) AS n, bool_and(fields ? '_msg' AND fields ? '_time') AS ok,
		bool_and(time > now() - interval '3 hours 1 minute') AS recent INTO r
	FROM (SELECT * FROM logs LIMIT 20) l;
	ASSERT r.n = 20 AND r.ok AND r.recent, r;
	req := remote($q$SELECT * FROM grafana_logs WHERE container = 'grafana' LIMIT 5$q$);
	ASSERT req LIKE '%query=*&start=%&extra_filters="kubernetes.container_name":="grafana"', req;
	SELECT count(*) AS n, bool_and(container = 'grafana') AS ok INTO r
	FROM (SELECT * FROM grafana_logs WHERE container = 'grafana' LIMIT 10) l;
	ASSERT r.n = 10 AND r.ok, r;
	SELECT count(*) AS n, bool_and(msg ~* 'error') AS ok INTO r
	FROM (SELECT * FROM logs WHERE query = 'error' LIMIT 10) l;
	ASSERT r.n = 10 AND r.ok, r;

	-- Errors.
	ASSERT err('SELECT * FROM metrics') LIKE 'HV004: victoria_fdw: a MetricsQL query is required', err('SELECT * FROM metrics');
	ASSERT err($q$SELECT * FROM metrics WHERE query = 'sum('$q$) LIKE 'HV000: GET %query=sum(%: HTTP 400: %unexpected token%';
	ASSERT err($q$SELECT * FROM logs WHERE query = 'foo:('$q$) LIKE 'HV000: %HTTP 400: cannot parse `query` arg%';
	ASSERT err($q$CREATE SERVER x FOREIGN DATA WRAPPER victoria_fdw OPTIONS (type 'traces', url 'http://x')$q$)
		LIKE '%invalid value for option "type"%';
	ASSERT err($q$CREATE SERVER x FOREIGN DATA WRAPPER victoria_fdw OPTIONS (type 'logs')$q$) LIKE '%option "url" is required%';
	ASSERT err($q$CREATE FOREIGN TABLE x (a text) SERVER vm OPTIONS (step '-1 minute')$q$) LIKE '%positive duration%';
	ASSERT err($q$CREATE FOREIGN TABLE x (a text) SERVER vm OPTIONS (bogus 'x')$q$) LIKE '%invalid option "bogus"%';
END $$;

-- Joins: queries stored in a table, sent once per row (parameterized nested
-- loop, the only possible plan since metrics needs a query).
CREATE TABLE panels (panel text, q text);
INSERT INTO panels VALUES ('targets', 'sum(up)'), ('series', 'count(up)'), ('none', 'absent_metric_xyz');
ANALYZE panels;
DO $$
DECLARE
	r record;
BEGIN
	ASSERT remote($q$SELECT * FROM panels p JOIN metrics m ON m.query = p.q AND m.time > now() - interval '10 minutes'$q$,
		'Remote Requests') = '3',
		remote($q$SELECT * FROM panels p JOIN metrics m ON m.query = p.q AND m.time > now() - interval '10 minutes'$q$, 'Remote Requests');
	SELECT count(*) FILTER (WHERE panel = 'targets') AS targets, count(*) FILTER (WHERE panel = 'series') AS series,
		count(*) FILTER (WHERE panel = 'none') AS none INTO r
	FROM panels p JOIN metrics m ON m.query = p.q AND m.time > now() - interval '10 minutes';
	ASSERT r.targets > 0 AND r.series > 0 AND r.none = 0, r::text;
END $$;

-- Joins with a local table on a label column: correct with any join method.
CREATE TABLE teams (job text PRIMARY KEY, team text);
INSERT INTO teams VALUES ('node-exporter', 'infra'), ('kube-state-metrics', 'platform'), ('no-such-job', 'nobody');
ANALYZE teams;
CREATE TEMP TABLE by_team AS
	SELECT t.team, count(*) AS n FROM teams t JOIN up_by_job u ON u.job = t.job
	WHERE u.time > now() - interval '10 minutes' GROUP BY 1;
SET enable_hashjoin = off;
SET enable_mergejoin = off;
DO $$
BEGIN
	-- same result with a nested loop
	ASSERT (SELECT array_agg(team ORDER BY team) FROM (
		SELECT t.team FROM teams t JOIN up_by_job u ON u.job = t.job
		WHERE u.time > now() - interval '10 minutes' GROUP BY 1) x) = (SELECT array_agg(team ORDER BY team) FROM by_team);
END $$;
RESET enable_hashjoin;
RESET enable_mergejoin;
DO $$
DECLARE
	req text;
BEGIN
	-- LATERAL: job = <outer row> is pushed down, one request per team
	ASSERT remote($q$SELECT t.team, c.n FROM teams t, LATERAL (SELECT count(*) AS n FROM up_by_job u
		WHERE u.job = t.job AND u.time > now() - interval '10 minutes') c$q$, 'Remote Requests') = '3';
	req := remote($q$SELECT t.team, c.n FROM teams t, LATERAL (SELECT count(*) AS n FROM up_by_job u
		WHERE u.job = t.job AND u.time > now() - interval '10 minutes') c$q$);
	ASSERT req LIKE '%extra_filters[]={job="no-such-job"}', req;
	ASSERT (SELECT array_agg(team ORDER BY team) FROM teams t, LATERAL (SELECT count(*) AS n FROM up_by_job u
		WHERE u.job = t.job AND u.time > now() - interval '10 minutes') c WHERE c.n > 0)
		= (SELECT array_agg(team ORDER BY team) FROM by_team);
END $$;

-- Metrics and logs together: log lines around the latest scrape of each
-- grafana target (LATERAL, a time window per outer row).
DO $$
BEGIN
	ASSERT (SELECT count(*) FROM (
		SELECT t.at, l.msg
		FROM (SELECT date_trunc('minute', now()) - interval '30 minutes' * g AS at FROM generate_series(1, 2) g) t,
		LATERAL (SELECT msg FROM grafana_logs WHERE container = 'grafana'
			AND time BETWEEN t.at - interval '15 minutes' AND t.at LIMIT 3) l) x) = 6;
END $$;

-- Cancellation: a long stream is interrupted by statement_timeout.
SET statement_timeout = '1s';
DO $$
BEGIN
	PERFORM count(*) FROM logs;
	RAISE 'expected a timeout';
EXCEPTION WHEN query_canceled THEN
END $$;
RESET statement_timeout;
