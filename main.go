// victoria_fdw is a PostgreSQL foreign data wrapper for VictoriaMetrics
// (MetricsQL) and VictoriaLogs (LogsQL), written in Go with gopgext:
// gopgext/fdw does the PostgreSQL side (planning, pushdown, joins, EXPLAIN),
// gopgext/http the requests.
package main

import (
	"errors"
	"fmt"
	"strconv"
	"strings"

	"gopgext/fdw"
	"gopgext/pg"
)

func main() {
	fdw.Register(fdw.Wrapper{
		Options: []fdw.Option{
			{Name: "url", Where: fdw.OnServer | fdw.OnTable, Required: fdw.OnServer, Check: checkURL},
			{Name: "type", Where: fdw.OnServer | fdw.OnTable, Check: checkType},
			{Name: "query", Where: fdw.OnTable},
			{Name: "default_range", Where: fdw.OnServer | fdw.OnTable, Check: checkDuration},
			{Name: "step", Where: fdw.OnServer | fdw.OnTable, Check: checkDuration},
			{Name: "limit", Where: fdw.OnServer | fdw.OnTable, Check: checkPositive},
			{Name: "timeout", Where: fdw.OnServer | fdw.OnTable, Check: checkPositive},
			{Name: "header", Where: fdw.OnServer | fdw.OnTable | fdw.OnUserMapping, Check: checkHeader},
			{Name: "name", Where: fdw.OnColumn},
		},
		Plan:   plan,
		Scan:   scan,
		Import: importSchema,
	})
}

func checkURL(v string) error {
	if !strings.HasPrefix(v, "http://") && !strings.HasPrefix(v, "https://") {
		return errors.New("use an http:// or https:// URL")
	}
	return nil
}

func checkType(v string) error {
	if v != "metrics" && v != "logs" {
		return errors.New("use 'metrics' (VictoriaMetrics) or 'logs' (VictoriaLogs)")
	}
	return nil
}

func checkDuration(v string) error {
	if d, err := parseDuration(v); err != nil || d <= 0 {
		return errors.New("use a positive duration, e.g. '3 hours' or '30m'")
	}
	return nil
}

func checkPositive(v string) error {
	if f, err := strconv.ParseFloat(v, 64); err != nil || f <= 0 {
		return errors.New("use a positive number")
	}
	return nil
}

func checkHeader(v string) error {
	if name, _, ok := strings.Cut(v, ":"); !ok || strings.TrimSpace(name) == "" {
		return errors.New(`use "Name: value"`)
	}
	return nil
}

// Column roles: some column names have a meaning, any other column is a
// label (metrics) or a field (logs).
type role int

const (
	roleOther role = iota
	roleTime
	roleQuery
	roleValue  // metrics
	roleMetric // metrics: __name__
	roleLabels // metrics: all labels
	roleStep   // metrics
	roleMsg    // logs: _msg
	roleStream // logs: _stream
	roleFields // logs: all fields
	roleDropped
)

// remoteName is the label/field a column reads: its name option, else its
// name.
func remoteName(c fdw.ColumnInfo) string {
	if n, ok := c.Options["name"]; ok {
		return n
	}
	return c.Name
}

func columnRole(logs bool, c fdw.ColumnInfo) role {
	if c.Dropped {
		return roleDropped
	}
	switch name := remoteName(c); {
	case name == "time":
		return roleTime
	case name == "query":
		return roleQuery
	case !logs && name == "value":
		return roleValue
	case !logs && name == "metric":
		return roleMetric
	case !logs && name == "labels":
		return roleLabels
	case !logs && name == "step":
		return roleStep
	case logs && name == "msg":
		return roleMsg
	case logs && name == "stream":
		return roleStream
	case logs && name == "fields":
		return roleFields
	}
	return roleOther
}

func isLogs(t *fdw.Table) (bool, error) {
	typ, ok := t.Option("type")
	if !ok {
		return false, &pg.Error{Code: "HV00J", Message: fmt.Sprintf("foreign table %q has no type option", t.Name),
			Hint: "Set type 'metrics' or 'logs' on the server or the foreign table."}
	}
	return typ == "logs", nil
}

var errQueryRequired = &pg.Error{Code: "HV004", Message: "victoria_fdw: a MetricsQL query is required",
	Hint: "Filter on the query column (WHERE query = 'rate(http_requests_total[5m])'), on the metric " +
		"column or a label column, or set the query option of the foreign table."}

// plan decides which conditions are sent to VictoriaMetrics/VictoriaLogs:
// time ranges, the query, label/field equalities and the step.
func plan(t *fdw.Table, conds []fdw.Condition) (fdw.Plan, error) {
	logs, err := isLogs(t)
	if err != nil {
		return fdw.Plan{}, err
	}
	p := fdw.Plan{Pushed: make([]bool, len(conds))}
	_, selector := t.Option("query")
	for i, c := range conds {
		switch columnRole(logs, t.Columns[c.Column]) {
		case roleTime:
			p.Pushed[i] = c.Kind == fdw.Time && c.Op != "<>"
		case roleStep:
			p.Pushed[i] = c.Op == "=" && (c.Kind == fdw.Interval || c.Kind == fdw.Text)
		case roleQuery, roleMetric, roleOther, roleMsg, roleStream:
			p.Pushed[i] = c.Op == "=" && c.Kind == fdw.Text
			selector = selector || p.Pushed[i]
		}
	}
	if !logs && !selector {
		return p, errQueryRequired
	}
	// Row estimates: a logs scan without a query or field filter returns
	// everything in the time range, so it's estimated large; the planner
	// then prefers plans that push join conditions down (one request per
	// outer row) over one unfiltered transfer joined locally.
	p.Rows = 1000
	if logs && !selector {
		p.Rows = 1e6
	}
	return p, nil
}

func scan(t *fdw.Table, vals []fdw.Value) (fdw.Rows, error) {
	logs, err := isLogs(t)
	if err != nil {
		return nil, err
	}
	r, err := newRequest(t, logs, vals)
	if err != nil {
		return nil, err
	}
	if r.impossible {
		return noRows{}, nil
	}
	if logs {
		return scanLogs(t, r)
	}
	return scanMetrics(t, r)
}

// importSchema: IMPORT FOREIGN SCHEMA metrics|logs FROM SERVER s INTO schema
// creates a foreign table with the standard columns.
func importSchema(s *fdw.ServerInfo, remote string) ([]string, error) {
	if remote != "metrics" && remote != "logs" {
		return nil, &pg.Error{Code: "HV00Q", Message: fmt.Sprintf("unknown remote schema %q", remote),
			Hint: `Import "metrics" (VictoriaMetrics) or "logs" (VictoriaLogs).`}
	}
	if typ, ok := s.Options["type"]; ok && typ != remote {
		return nil, pg.Errorf("HV00Q", "server %q is a %s server", s.Name, typ)
	}
	cols := "time timestamptz, metric text, labels jsonb, value float8, query text, step interval"
	if remote == "logs" {
		cols = "time timestamptz, msg text, stream text, fields jsonb, query text"
	}
	return []string{fmt.Sprintf("CREATE FOREIGN TABLE %s (%s) SERVER %s OPTIONS (type %s)",
		fdw.QuoteIdent(remote), cols, fdw.QuoteIdent(s.Name), fdw.QuoteLiteral(remote))}, nil
}

type noRows struct{}

func (noRows) Next() ([]any, error) { return nil, nil }
func (noRows) Close() error         { return nil }
func (noRows) Describe() string     { return "none (the conditions can't match)" }
