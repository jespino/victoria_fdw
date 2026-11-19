package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strconv"
	"strings"
	"time"

	"gopgext/fdw"
	"gopgext/http"
	"gopgext/pg"
)

// defaultRange is the time range without a lower bound: the last 3 hours.
const defaultRange = 3 * time.Hour

// request is what a scan asks VictoriaMetrics/VictoriaLogs for, from the
// pushed-down conditions and the options.
type request struct {
	base       string // url option
	start, end time.Time
	instant    bool              // time = x
	impossible bool              // the conditions can't match: no request
	query      string            // query condition (or the query option)
	filters    map[string]string // label/field = value (remote names)
	step       string            // step condition, in VictoriaMetrics syntax
	stepText   string            // value of the step column
	client     *http.Client
}

func newRequest(t *fdw.Table, logs bool, vals []fdw.Value) (*request, error) {
	r := &request{filters: map[string]string{}}
	r.base, _ = t.Option("url")
	r.base = strings.TrimRight(r.base, "/")
	r.query, _ = t.Option("query")

	var lower, upper, at *time.Time
	equal := func(m map[string]string, k, v string) {
		if prev, ok := m[k]; ok && prev != v {
			r.impossible = true // col = 'a' AND col = 'b'
		}
		m[k] = v
	}
	eq := map[string]string{} // role-specific equalities: query, step
	for _, v := range vals {
		col := t.Columns[v.Column]
		if v.Null {
			r.impossible = true
			continue
		}
		switch columnRole(logs, col) {
		case roleTime:
			if v.Inf != 0 {
				// x > -infinity, x < infinity: no bound; the rest can't match
				if (v.Inf < 0) != (v.Op == ">" || v.Op == ">=") {
					r.impossible = true
				}
				continue
			}
			tm := v.Time
			switch v.Op {
			case ">", ">=":
				if lower == nil || tm.After(*lower) {
					lower = &tm
				}
			case "<", "<=":
				if upper == nil || tm.Before(*upper) {
					upper = &tm
				}
			case "=":
				if at != nil && !at.Equal(tm) {
					r.impossible = true
				}
				at = &tm
			}
		case roleQuery:
			equal(eq, "query", v.Text)
		case roleStep:
			if v.Kind == fdw.Interval {
				secs := v.Interval.Seconds()
				equal(eq, "step", strconv.FormatFloat(secs, 'f', -1, 64))
				r.stepText = strconv.FormatFloat(secs, 'f', -1, 64) + " seconds"
			} else {
				equal(eq, "step", v.Text)
				r.stepText = v.Text
			}
		case roleMetric:
			equal(r.filters, "__name__", v.Text)
		case roleMsg:
			equal(r.filters, "_msg", v.Text)
		case roleStream:
			equal(r.filters, "_stream", v.Text)
		default:
			equal(r.filters, remoteName(col), v.Text)
		}
	}
	if q, ok := eq["query"]; ok {
		r.query = q
	}
	r.step = eq["step"]

	// The time range: [x, x] for time = x; else the bounds, with now (the
	// statement start) as the default end and default_range before the end
	// as the default start.
	if at != nil {
		if (lower != nil && at.Before(*lower)) || (upper != nil && at.After(*upper)) {
			r.impossible = true
		}
		r.start, r.end, r.instant = *at, *at, true
	} else {
		rng := defaultRange
		if v, ok := t.Option("default_range"); ok {
			rng, _ = parseDuration(v)
		}
		r.end = fdw.Now()
		if upper != nil {
			r.end = *upper
		}
		r.start = r.end.Add(-rng)
		if lower != nil {
			r.start = *lower
		}
		if r.start.After(r.end) {
			r.impossible = true
		}
	}

	timeout := 300 * time.Second
	if v, ok := t.Option("timeout"); ok {
		secs, _ := strconv.ParseFloat(v, 64)
		timeout = time.Duration(secs * float64(time.Second))
	}
	r.client = &http.Client{Timeout: timeout, Header: http.Header{}}
	if h, ok := t.Option("header"); ok {
		name, value, _ := strings.Cut(h, ":")
		r.client.Header.Set(strings.TrimSpace(name), strings.TrimSpace(value))
	}
	return r, nil
}

// remoteErr is an error talking to the remote server (SQLSTATE HV000,
// fdw_error).
func remoteErr(format string, args ...any) error {
	return pg.Errorf("HV000", format, args...)
}

// get sends a request and checks its status: errors carry the server's
// message.
func (r *request) get(endpoint string, params [][2]string) (*http.Response, string, error) {
	desc := describeRequest(endpoint, params)
	resp, err := r.client.Get(endpoint + "?" + encodeQuery(params))
	if err != nil {
		var herr *http.Error
		if errors.As(err, &herr) {
			return nil, desc, remoteErr("%s failed: %s", desc, herr.Err)
		}
		return nil, desc, err // e.g. canceled
	}
	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		defer resp.Body.Close()
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 64<<10))
		msg := strings.TrimSpace(string(body))
		var e struct {
			Error string `json:"error"`
		}
		if json.Unmarshal(body, &e) == nil && e.Error != "" {
			msg = e.Error
		}
		if len(msg) > 2000 {
			msg = msg[:2000] + "..."
		}
		return nil, desc, remoteErr("%s: HTTP %d: %s", desc, resp.StatusCode, msg)
	}
	return resp, desc, nil
}

// describeRequest renders a request readably (EXPLAIN ANALYZE, errors).
func describeRequest(endpoint string, params [][2]string) string {
	var sb strings.Builder
	sb.WriteString("GET " + endpoint)
	for i, p := range params {
		sep := "&"
		if i == 0 {
			sep = "?"
		}
		sb.WriteString(sep + p[0] + "=" + p[1])
	}
	return sb.String()
}

func encodeQuery(params [][2]string) string {
	const hex = "0123456789ABCDEF"
	var sb strings.Builder
	for i, p := range params {
		if i > 0 {
			sb.WriteByte('&')
		}
		for j, s := range p {
			if j == 1 {
				sb.WriteByte('=')
			}
			for k := 0; k < len(s); k++ {
				c := s[k]
				if c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '-' || c == '_' || c == '.' || c == '~' {
					sb.WriteByte(c)
				} else {
					sb.WriteString("%" + string(hex[c>>4]) + string(hex[c&15]))
				}
			}
		}
	}
	return sb.String()
}

func sortedKeys(m map[string]string) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	for i := 1; i < len(keys); i++ {
		for j := i; j > 0 && keys[j] < keys[j-1]; j-- {
			keys[j], keys[j-1] = keys[j-1], keys[j]
		}
	}
	return keys
}

func jsonText(v any) json.RawMessage {
	var b bytes.Buffer
	enc := json.NewEncoder(&b)
	enc.SetEscapeHTML(false)
	enc.Encode(v)
	return bytes.TrimSuffix(b.Bytes(), []byte("\n"))
}

var units = map[string]time.Duration{
	"us": time.Microsecond, "usec": time.Microsecond, "microsecond": time.Microsecond,
	"ms": time.Millisecond, "msec": time.Millisecond, "millisecond": time.Millisecond,
	"s": time.Second, "sec": time.Second, "second": time.Second,
	"m": time.Minute, "min": time.Minute, "minute": time.Minute,
	"h": time.Hour, "hr": time.Hour, "hour": time.Hour,
	"d": 24 * time.Hour, "day": 24 * time.Hour,
	"w": 7 * 24 * time.Hour, "week": 7 * 24 * time.Hour,
}

// parseDuration parses durations like "3h", "90m", "3 hours", "1 day 2
// hours" or "01:30:00".
func parseDuration(s string) (time.Duration, error) {
	s = strings.TrimSpace(strings.ToLower(s))
	if d, err := time.ParseDuration(s); err == nil {
		return d, nil
	}
	if f := strings.Split(s, ":"); len(f) == 3 {
		h, e1 := strconv.Atoi(f[0])
		m, e2 := strconv.Atoi(f[1])
		sec, e3 := strconv.ParseFloat(f[2], 64)
		if e1 == nil && e2 == nil && e3 == nil {
			return time.Duration(h)*time.Hour + time.Duration(m)*time.Minute +
				time.Duration(sec*float64(time.Second)), nil
		}
	}
	fields := strings.Fields(s)
	if len(fields) == 0 || len(fields)%2 != 0 {
		return 0, fmt.Errorf("invalid duration %q", s)
	}
	var d time.Duration
	for i := 0; i < len(fields); i += 2 {
		n, err := strconv.ParseFloat(fields[i], 64)
		unit, ok := units[fields[i+1]] // exact first: "ms" isn't plural "m"
		if !ok {
			unit, ok = units[strings.TrimSuffix(fields[i+1], "s")]
		}
		if err != nil || !ok {
			return 0, fmt.Errorf("invalid duration %q", s)
		}
		d += time.Duration(n * float64(unit))
	}
	return d, nil
}
