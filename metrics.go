package main

import (
	"encoding/json"
	"io"
	"math"
	"regexp"
	"strconv"
	"strings"
	"time"

	"gopgext/fdw"
	"gopgext/pg"
)

// VictoriaMetrics: /api/v1/query_range (or /api/v1/query for time = x) of
// the Prometheus-compatible API at the url option, e.g.
// https://play.victoriametrics.com/select/0/prometheus.
//
// Columns: time, value, metric (__name__), labels (all, as JSON), query
// (the MetricsQL query), step; any other column is the label of that name.

type metricRows struct {
	cols   []role
	names  []string // remote names (labels)
	desc   string
	query  string // value of the query column
	step   any    // value of the step column
	series []series
	si, pi int
}

type series struct {
	labels     map[string]string
	labelsJSON json.RawMessage
	points     []point
}

type point struct {
	ts    float64
	value string
}

var labelNameRe = regexp.MustCompile(`^[a-zA-Z_][a-zA-Z0-9_]*$`)

func matcher(name, value string) string {
	if !labelNameRe.MatchString(name) {
		name = strconv.Quote(name)
	}
	return name + "=" + strconv.Quote(value)
}

func unixSeconds(t time.Time) string {
	return strconv.FormatFloat(float64(t.UnixMicro())/1e6, 'f', 3, 64)
}

func scanMetrics(t *fdw.Table, r *request) (fdw.Rows, error) {
	m := &metricRows{}
	for _, c := range t.Columns {
		m.cols = append(m.cols, columnRole(false, c))
		m.names = append(m.names, remoteName(c))
	}
	var matchers []string
	for _, k := range sortedKeys(r.filters) {
		matchers = append(matchers, matcher(k, r.filters[k]))
	}
	query := r.query
	if query == "" {
		if len(matchers) == 0 {
			return nil, errQueryRequired
		}
		// No query: select the series by name/labels.
		query = "{" + strings.Join(matchers, ",") + "}"
		matchers = nil
	}
	m.query = query

	var endpoint string
	params := [][2]string{{"query", query}}
	if r.instant {
		endpoint = r.base + "/api/v1/query"
		params = append(params, [2]string{"time", unixSeconds(r.start)})
	} else {
		step := r.step
		m.step = r.stepText
		if step == "" {
			// default: about 300 points per series
			secs := math.Max(1, math.Ceil(r.end.Sub(r.start).Seconds()/300))
			if v, ok := t.Option("step"); ok {
				d, _ := parseDuration(v)
				secs = d.Seconds()
			}
			step = strconv.FormatFloat(secs, 'f', -1, 64)
			m.step = step + " seconds"
		}
		endpoint = r.base + "/api/v1/query_range"
		params = append(params, [2]string{"start", unixSeconds(r.start)},
			[2]string{"end", unixSeconds(r.end)}, [2]string{"step", step})
	}
	if len(matchers) > 0 {
		// One extra_filters[] with all the matchers: several are ORed.
		params = append(params, [2]string{"extra_filters[]", "{" + strings.Join(matchers, ",") + "}"})
	}
	resp, desc, err := r.get(endpoint, params)
	m.desc = desc
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}
	return m, m.parse(body)
}

func (m *metricRows) parse(body []byte) error {
	var resp struct {
		Status string `json:"status"`
		Error  string `json:"error"`
		Data   struct {
			ResultType string          `json:"resultType"`
			Result     json.RawMessage `json:"result"`
		} `json:"data"`
	}
	if err := json.Unmarshal(body, &resp); err != nil {
		return remoteErr("VictoriaMetrics: invalid response: %v", err)
	}
	if resp.Status != "success" {
		return remoteErr("VictoriaMetrics: %s", resp.Error)
	}
	switch resp.Data.ResultType {
	case "matrix":
		var r []struct {
			Metric map[string]string `json:"metric"`
			Values [][]any           `json:"values"`
		}
		if err := json.Unmarshal(resp.Data.Result, &r); err != nil {
			return remoteErr("VictoriaMetrics: invalid matrix: %v", err)
		}
		for _, s := range r {
			m.series = append(m.series, newSeries(s.Metric, s.Values...))
		}
	case "vector":
		var r []struct {
			Metric map[string]string `json:"metric"`
			Value  []any             `json:"value"`
		}
		if err := json.Unmarshal(resp.Data.Result, &r); err != nil {
			return remoteErr("VictoriaMetrics: invalid vector: %v", err)
		}
		for _, s := range r {
			m.series = append(m.series, newSeries(s.Metric, s.Value))
		}
	case "scalar", "string":
		var r []any
		if err := json.Unmarshal(resp.Data.Result, &r); err != nil {
			return remoteErr("VictoriaMetrics: invalid %s: %v", resp.Data.ResultType, err)
		}
		m.series = append(m.series, newSeries(nil, r))
	default:
		return pg.Errorf("HV000", "VictoriaMetrics: unsupported result type %q", resp.Data.ResultType)
	}
	return nil
}

func newSeries(labels map[string]string, samples ...[]any) series {
	if labels == nil {
		labels = map[string]string{}
	}
	s := series{labels: labels, labelsJSON: jsonText(labels)}
	for _, smp := range samples {
		if len(smp) == 2 {
			ts, _ := smp[0].(float64)
			v, _ := smp[1].(string)
			s.points = append(s.points, point{ts, v})
		}
	}
	return s
}

func (m *metricRows) Next() ([]any, error) {
	for m.si < len(m.series) && m.pi >= len(m.series[m.si].points) {
		m.si++
		m.pi = 0
	}
	if m.si >= len(m.series) {
		return nil, nil
	}
	s := &m.series[m.si]
	p := s.points[m.pi]
	m.pi++
	row := make([]any, len(m.cols))
	for i, r := range m.cols {
		switch r {
		case roleTime:
			row[i] = time.UnixMilli(int64(math.Round(p.ts * 1000))).UTC()
		case roleValue:
			row[i] = p.value
		case roleMetric:
			if v, ok := s.labels["__name__"]; ok {
				row[i] = v
			}
		case roleLabels:
			row[i] = s.labelsJSON
		case roleQuery:
			row[i] = m.query
		case roleStep:
			if m.step != "" {
				row[i] = m.step
			}
		case roleOther:
			if v, ok := s.labels[m.names[i]]; ok {
				row[i] = v
			}
		}
	}
	return row, nil
}

func (m *metricRows) Close() error     { return nil }
func (m *metricRows) Describe() string { return m.desc }
