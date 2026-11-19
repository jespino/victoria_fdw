-- shop_ops: an ops/business database for the company running the
-- OpenTelemetry demo shop that play.victoriametrics.com monitors. Its
-- services, hosts and nodes are the real ones (container, instance and
-- node names from the playground), so it joins with live metrics and logs
-- through victoria_fdw. The rest (teams, deployments, incidents, orders...)
-- is generated, with timestamps relative to when the script runs.
--
--   createdb -h localhost -U postgres shop_ops
--   psql -h localhost -U postgres -d shop_ops -f demo/shop_ops.sql
--
-- Re-running it recreates everything (and refreshes the timestamps).

\set ON_ERROR_STOP 1
SET client_min_messages = warning;
SELECT setseed(0.2026);

DROP SCHEMA IF EXISTS vm, vl CASCADE;
DROP TABLE IF EXISTS teams, engineers, services, service_dependencies, hosts, k8s_nodes,
	oncall_shifts, deployments, incidents, customers, orders, dashboards CASCADE;

-- ---- Organization ----------------------------------------------------

CREATE TABLE teams (
	id            int PRIMARY KEY,
	name          text NOT NULL UNIQUE,
	slack_channel text NOT NULL,
	cost_center   text NOT NULL,
	manager       text NOT NULL
);
INSERT INTO teams VALUES
	(1, 'Storefront',          '#team-storefront', 'CC-1010', 'Lucía Fernández'),
	(2, 'Checkout & Payments', '#team-checkout',   'CC-1020', 'Daniel Okafor'),
	(3, 'Fulfillment',         '#team-fulfillment','CC-1030', 'Mei Lin'),
	(4, 'Platform',            '#team-platform',   'CC-1040', 'Arjun Mehta');

CREATE TABLE engineers (
	id       int PRIMARY KEY,
	name     text NOT NULL,
	email    text NOT NULL UNIQUE,
	team_id  int NOT NULL REFERENCES teams,
	role     text NOT NULL,
	timezone text NOT NULL,
	hired_on date NOT NULL
);
INSERT INTO engineers
SELECT i, n, lower(replace(split_part(n, ' ', 1), 'í', 'i')) || '.' || lower(split_part(n, ' ', 2)) || '@shop.example',
	((i - 1) % 4) + 1,
	(ARRAY['Senior Engineer', 'Engineer', 'Staff Engineer', 'SRE', 'Engineer'])[1 + (i % 5)],
	(ARRAY['Europe/Madrid', 'America/New_York', 'Asia/Singapore', 'Europe/Berlin', 'America/Los_Angeles'])[1 + (i % 5)],
	date '2019-01-01' + (i * 97 % 2200)::int
FROM unnest(ARRAY['Ana García', 'Tom Becker', 'Priya Nair', 'Lars Olsen', 'Sofia Rossi', 'Kenji Watanabe',
	'Amara Diallo', 'Hugo Martin', 'Elena Petrova', 'Carlos Ruiz', 'Nora Jensen', 'Omar Haddad',
	'Julia Novak', 'Ravi Kumar', 'Chloe Dubois', 'Mateo López']) WITH ORDINALITY AS t(n, i);

-- The services of the demo shop: name = the container label of the
-- metrics and the kubernetes.container_name field of the logs.
CREATE TABLE services (
	name               text PRIMARY KEY,
	team_id            int NOT NULL REFERENCES teams,
	tier               text NOT NULL CHECK (tier IN ('critical', 'high', 'standard')),
	language           text NOT NULL,
	repo               text,
	description        text NOT NULL,
	slo_availability   numeric(5, 3) NOT NULL,
	slo_p99_ms         int,
	monthly_budget_usd numeric(10, 2) NOT NULL
);
INSERT INTO services (name, team_id, tier, language, description, slo_availability, slo_p99_ms, monthly_budget_usd) VALUES
	('frontend',                1, 'critical', 'TypeScript', 'Web storefront (Next.js)',                 99.950, 400, 4200),
	('frontend-proxy',          1, 'critical', 'C++',        'Envoy edge proxy',                         99.990, 100, 1800),
	('image-provider',          1, 'standard', 'nginx',      'Product images',                           99.500, 200,  300),
	('ad',                      1, 'standard', 'Java',       'Contextual ads',                           99.000, 300,  900),
	('recommendation',          1, 'high',     'Python',     'Product recommendations',                  99.500, 300, 1500),
	('product-catalog',         1, 'critical', 'Go',         'Product catalog API',                      99.950, 150, 1200),
	('cart',                    2, 'critical', 'C#',         'Shopping cart',                            99.950, 200, 1600),
	('valkey-cart',             2, 'critical', 'Valkey',     'Cart storage',                             99.990,  50,  700),
	('checkout',                2, 'critical', 'Go',         'Order placement',                          99.990, 500, 2100),
	('payment',                 2, 'critical', 'JavaScript', 'Payment processing',                       99.990, 700, 2500),
	('currency',                2, 'high',     'C++',        'Currency conversion',                      99.900, 100,  600),
	('fraud-detection',         2, 'high',     'Kotlin',     'Fraud scoring (Kafka consumer)',           99.500, NULL, 1300),
	('shipping',                3, 'high',     'Rust',       'Shipping quotes and tracking',             99.900, 300,  800),
	('quote',                   3, 'standard', 'PHP',        'Shipping cost quotes',                     99.500, 300,  400),
	('email',                   3, 'standard', 'Ruby',       'Order confirmation emails',                99.000, NULL, 350),
	('accounting',              3, 'standard', 'C#',         'Order accounting (Kafka consumer)',        99.000, NULL, 650),
	('kafka',                   4, 'critical', 'Java',       'Event bus',                                99.990, NULL, 3100),
	('postgresql',              4, 'critical', 'C',          'Accounting database',                      99.990, NULL, 1900),
	('flagd',                   4, 'high',     'Go',         'Feature flags',                            99.900,  50,  250),
	('opentelemetry-collector', 4, 'high',     'Go',         'Telemetry pipeline',                       99.900, NULL, 1100),
	('grafana',                 4, 'standard', 'Go',         'Dashboards',                               99.500, NULL, 450),
	('load-generator',          4, 'standard', 'Python',     'Synthetic traffic (Locust)',               95.000, NULL, 500);
UPDATE services SET repo = 'github.com/shop-example/' || name;
ALTER TABLE services ALTER COLUMN repo SET NOT NULL;

CREATE TABLE service_dependencies (
	service    text REFERENCES services,
	depends_on text REFERENCES services,
	PRIMARY KEY (service, depends_on)
);
INSERT INTO service_dependencies VALUES
	('frontend-proxy', 'frontend'), ('frontend-proxy', 'image-provider'), ('frontend-proxy', 'flagd'),
	('frontend', 'ad'), ('frontend', 'cart'), ('frontend', 'checkout'), ('frontend', 'currency'),
	('frontend', 'product-catalog'), ('frontend', 'recommendation'), ('frontend', 'shipping'),
	('recommendation', 'product-catalog'), ('cart', 'valkey-cart'), ('checkout', 'cart'),
	('checkout', 'currency'), ('checkout', 'email'), ('checkout', 'payment'), ('checkout', 'product-catalog'),
	('checkout', 'shipping'), ('checkout', 'kafka'), ('shipping', 'quote'), ('accounting', 'kafka'),
	('accounting', 'postgresql'), ('fraud-detection', 'kafka');

-- ---- Infrastructure ----------------------------------------------------

-- The 13 hosts that node-exporter scrapes (instance label).
CREATE TABLE hosts (
	instance         text PRIMARY KEY,
	hostname         text NOT NULL UNIQUE,
	zone             text NOT NULL,
	rack             text NOT NULL,
	model            text NOT NULL,
	cpu_cores        int NOT NULL,
	memory_gb        int NOT NULL,
	purchased_on     date NOT NULL,
	monthly_cost_usd numeric(10, 2) NOT NULL,
	owner_team_id    int NOT NULL REFERENCES teams
);
INSERT INTO hosts
SELECT inst, format('node-%s', lpad(i::text, 2, '0')),
	(ARRAY['us-east1-b', 'us-east1-c', 'us-east1-d'])[1 + (i % 3)],
	format('r%s-%s', 1 + i / 5, chr((97 + i % 5)::int)),
	CASE WHEN i % 4 = 0 THEN 'n2d-highmem-8' ELSE 'n2d-standard-8' END,
	8, CASE WHEN i % 4 = 0 THEN 64 ELSE 32 END,
	date '2024-03-01' + (i * 37)::int,
	CASE WHEN i % 4 = 0 THEN 412.00 ELSE 278.50 END,
	CASE WHEN i <= 4 THEN 4 ELSE 1 + (i % 3) END
FROM unnest(ARRAY['10.142.0.102:9100', '10.142.0.106:9100', '10.142.0.16:9100', '10.142.0.19:9100',
	'10.142.0.25:9100', '10.142.0.38:9100', '10.142.0.3:9100', '10.142.0.52:9100', '10.142.0.62:9100',
	'10.142.0.68:9100', '10.142.0.75:9100', '10.142.0.84:9100', '10.142.0.9:9100']) WITH ORDINALITY AS t(inst, i);

-- The Kubernetes nodes the shop runs on (k8s.node.name label,
-- kubernetes.pod_node_name log field).
CREATE TABLE k8s_nodes (
	name            text PRIMARY KEY,
	pool            text NOT NULL,
	machine_type    text NOT NULL,
	zone            text NOT NULL,
	hourly_cost_usd numeric(8, 4) NOT NULL
);
INSERT INTO k8s_nodes VALUES
	('gke-sandbox-n2d-std-8-202603301026051-852214e6-kdpk', 'default-pool', 'n2d-standard-8', 'us-east1-b', 0.3383),
	('gke-sandbox-n2d-std-8-202603301026051-852214e6-kfo8', 'default-pool', 'n2d-standard-8', 'us-east1-b', 0.3383),
	('gke-sandbox-n2d-std-8-202603301026051-852214e6-lu1k', 'default-pool', 'n2d-standard-8', 'us-east1-b', 0.3383),
	('gke-sandbox-n2d-std-8-202603301026051-852214e6-u67c', 'default-pool', 'n2d-standard-8', 'us-east1-b', 0.3383);

-- ---- Operations ----------------------------------------------------------

-- On-call: one engineer per team, 8-hour shifts, from a day ago to a day ahead.
CREATE TABLE oncall_shifts (
	team_id     int NOT NULL REFERENCES teams,
	engineer_id int NOT NULL REFERENCES engineers,
	starts_at   timestamptz NOT NULL,
	ends_at     timestamptz NOT NULL
);
INSERT INTO oncall_shifts
SELECT t.id, e.id, s, s + interval '8 hours'
FROM teams t,
	generate_series(date_trunc('hour', now()) - interval '24 hours', now() + interval '24 hours', interval '8 hours') WITH ORDINALITY AS g(s, k),
	LATERAL (SELECT id FROM engineers WHERE team_id = t.id ORDER BY id OFFSET (k % 4) LIMIT 1) e;

-- Deployments over the last 24 hours (most within the last 3).
CREATE TABLE deployments (
	id            serial PRIMARY KEY,
	service       text NOT NULL REFERENCES services,
	version       text NOT NULL,
	deployed_at   timestamptz NOT NULL,
	deployed_by   int NOT NULL REFERENCES engineers,
	status        text NOT NULL CHECK (status IN ('succeeded', 'rolled_back')),
	change_ticket text NOT NULL
);
INSERT INTO deployments (service, version, deployed_at, deployed_by, status, change_ticket)
SELECT s.name,
	format('2.%s.%s', 1 + (random() * 3)::int, (random() * 20)::int),
	date_trunc('minute', now() - CASE WHEN random() < 0.6 THEN random() * interval '3 hours' ELSE random() * interval '24 hours' END),
	(SELECT id FROM engineers WHERE team_id = s.team_id ORDER BY random() LIMIT 1),
	CASE WHEN random() < 0.12 THEN 'rolled_back' ELSE 'succeeded' END,
	format('CHG-%s', 4000 + (random() * 999)::int)
FROM services s, generate_series(1, 3) g
WHERE random() < 0.55;

-- Incidents over the last 2 days.
CREATE TABLE incidents (
	id             serial PRIMARY KEY,
	service        text NOT NULL REFERENCES services,
	severity       text NOT NULL CHECK (severity IN ('sev1', 'sev2', 'sev3')),
	title          text NOT NULL,
	started_at     timestamptz NOT NULL,
	resolved_at    timestamptz,
	commander_id   int REFERENCES engineers,
	postmortem_url text
);
INSERT INTO incidents (service, severity, title, started_at, resolved_at, commander_id, postmortem_url) VALUES
	('checkout',        'sev1', 'Checkout errors after payment timeout',      now() - interval '26 hours', now() - interval '25 hours 10 minutes', 2, 'https://wiki.shop.example/pm/1841'),
	('cart',            'sev2', 'Cart latency spike (valkey evictions)',      now() - interval '7 hours',  now() - interval '6 hours 20 minutes', 6, 'https://wiki.shop.example/pm/1843'),
	('kafka',           'sev2', 'Consumer lag on orders topic',               now() - interval '2 hours',  now() - interval '1 hour 15 minutes', 4, NULL),
	('recommendation',  'sev3', 'Stale recommendations',                      now() - interval '90 minutes', now() - interval '40 minutes', 1, NULL),
	('frontend',        'sev2', 'Elevated p99 on product pages',              now() - interval '35 minutes', NULL, 5, NULL),
	('email',           'sev3', 'Confirmation emails delayed',                now() - interval '13 hours', now() - interval '11 hours', 3, NULL);

-- ---- Business data ---------------------------------------------------------

CREATE TABLE customers (
	id         int PRIMARY KEY,
	name       text NOT NULL,
	country    text NOT NULL,
	segment    text NOT NULL,
	created_at timestamptz NOT NULL
);
INSERT INTO customers
SELECT i,
	(ARRAY['Alex', 'Sam', 'Maria', 'Wei', 'Fatima', 'John', 'Aiko', 'Pedro', 'Ingrid', 'Kofi'])[1 + (i % 10)] || ' ' ||
	(ARRAY['Smith', 'Silva', 'Chen', 'Müller', 'Ahmed', 'Kowalski', 'Tanaka', 'Rossi', 'Johansson', 'Mensah'])[1 + (i * 7 % 10)],
	(ARRAY['US', 'US', 'US', 'DE', 'ES', 'GB', 'FR', 'JP', 'BR', 'CA'])[1 + (i * 3 % 10)],
	(ARRAY['consumer', 'consumer', 'consumer', 'business', 'vip'])[1 + (i % 5)],
	now() - (i % 900) * interval '1 day'
FROM generate_series(1, 2000) i;

-- Orders over the last 24 hours, following a daily traffic curve.
CREATE TABLE orders (
	id             bigserial PRIMARY KEY,
	customer_id    int NOT NULL REFERENCES customers,
	created_at     timestamptz NOT NULL,
	total_usd      numeric(10, 2) NOT NULL,
	items          int NOT NULL,
	status         text NOT NULL,
	payment_method text NOT NULL,
	ship_country   text NOT NULL
);
INSERT INTO orders (customer_id, created_at, total_usd, items, status, payment_method, ship_country)
SELECT c.id, t,
	round((15 + random() * random() * 400)::numeric, 2),
	1 + (random() * random() * 6)::int,
	(ARRAY['paid', 'paid', 'paid', 'paid', 'paid', 'shipped', 'shipped', 'refunded', 'payment_failed'])[1 + (random() * 8)::int],
	(ARRAY['card', 'card', 'card', 'paypal', 'apple_pay', 'bank_transfer'])[1 + (random() * 5)::int],
	c.country
FROM generate_series(now() - interval '24 hours', now(), interval '5 seconds') t
CROSS JOIN LATERAL (SELECT 1 + (random() * 1999)::int AS id) r
JOIN customers c ON c.id = r.id
WHERE random() < 0.35 + 0.3 * sin(extract(epoch FROM t) / 86400 * 2 * pi());
CREATE INDEX ON orders (created_at);

-- Dashboard panels: MetricsQL queries stored as data.
CREATE TABLE dashboards (
	panel       text PRIMARY KEY,
	unit        text NOT NULL,
	query       text NOT NULL
);
INSERT INTO dashboards VALUES
	('Frontend requests/s',        'req/s', 'sum(rate(http_server_duration_milliseconds_count{"service.name"="frontend"}[5m]))'),
	('Frontend p99 latency',       'ms',    'histogram_quantile(0.99, sum(rate(http_server_duration_milliseconds_bucket{"service.name"="frontend"}[5m])) by (le))'),
	('Shop CPU cores',             'cores', 'sum(rate(container_cpu_usage_seconds_total{namespace="play-otel",container!=""}[5m]))'),
	('Hosts up',                   'hosts', 'sum(up{job="node-exporter"})'),
	('Avg host CPU utilization',   'ratio', '1 - avg(rate(node_cpu_seconds_total{mode="idle"}[5m]))');

-- ---- VictoriaMetrics and VictoriaLogs (play servers) ----------------------

CREATE EXTENSION IF NOT EXISTS victoria_fdw;
DROP SERVER IF EXISTS play_metrics, play_logs CASCADE;
CREATE SERVER play_metrics FOREIGN DATA WRAPPER victoria_fdw
	OPTIONS (type 'metrics', url 'https://play.victoriametrics.com/select/0/prometheus');
CREATE SERVER play_logs FOREIGN DATA WRAPPER victoria_fdw
	OPTIONS (type 'logs', url 'https://play-vmlogs.victoriametrics.com');
CREATE SCHEMA vm;
CREATE SCHEMA vl;

-- Generic tables: any MetricsQL / LogsQL query.
IMPORT FOREIGN SCHEMA metrics FROM SERVER play_metrics INTO vm;
IMPORT FOREIGN SCHEMA logs FROM SERVER play_logs INTO vl;

-- CPU used by each container of the shop (cores).
CREATE FOREIGN TABLE vm.container_cpu (time timestamptz, cores float8 OPTIONS (name 'value'), container text) SERVER play_metrics
	OPTIONS (query 'sum(rate(container_cpu_usage_seconds_total{namespace="play-otel",container!=""}[5m])) by (container)');

-- CPU utilization (0-1) and memory available (ratio) of each host.
CREATE FOREIGN TABLE vm.host_cpu (time timestamptz, utilization float8 OPTIONS (name 'value'), instance text) SERVER play_metrics
	OPTIONS (query '1 - avg(rate(node_cpu_seconds_total{mode="idle"}[5m])) by (instance)');
CREATE FOREIGN TABLE vm.host_memory (time timestamptz, available_ratio float8 OPTIONS (name 'value'), instance text) SERVER play_metrics
	OPTIONS (query 'node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes');

-- Frontend request rate and p99 latency (OpenTelemetry HTTP metrics).
CREATE FOREIGN TABLE vm.http_requests (time timestamptz, per_second float8 OPTIONS (name 'value'),
	service text OPTIONS (name 'service.name'), status text OPTIONS (name 'http.status_code'), step interval) SERVER play_metrics
	OPTIONS (query 'sum(rate(http_server_duration_milliseconds_count[5m])) by ("service.name", "http.status_code")');
CREATE FOREIGN TABLE vm.http_p99 (time timestamptz, ms float8 OPTIONS (name 'value'),
	service text OPTIONS (name 'service.name')) SERVER play_metrics
	OPTIONS (query 'histogram_quantile(0.99, sum(rate(http_server_duration_milliseconds_bucket[5m])) by (le, "service.name"))');

-- Scrape targets.
CREATE FOREIGN TABLE vm.up (time timestamptz, value float8, job text, instance text) SERVER play_metrics
	OPTIONS (query 'up');

-- Logs of the shop's pods.
CREATE FOREIGN TABLE vl.shop_logs (
	time      timestamptz,
	msg       text,
	container text OPTIONS (name 'kubernetes.container_name'),
	pod       text OPTIONS (name 'kubernetes.pod_name'),
	node      text OPTIONS (name 'kubernetes.pod_node_name'),
	output    text OPTIONS (name 'output_stream'),
	query     text
) SERVER play_logs OPTIONS (query 'kubernetes.pod_namespace:="play-otel"');

ANALYZE;
SELECT 'teams' AS table, count(*) FROM teams UNION ALL SELECT 'engineers', count(*) FROM engineers
UNION ALL SELECT 'services', count(*) FROM services UNION ALL SELECT 'hosts', count(*) FROM hosts
UNION ALL SELECT 'deployments', count(*) FROM deployments UNION ALL SELECT 'incidents', count(*) FROM incidents
UNION ALL SELECT 'customers', count(*) FROM customers UNION ALL SELECT 'orders', count(*) FROM orders;
