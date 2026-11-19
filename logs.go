package main

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strconv"
	"strings"
	"time"

	"gopgext/fdw"
	"gopgext/http"
)

// VictoriaLogs: /select/logsql/query at the url option, e.g.
// https://play-vmlogs.victoriametrics.com. The response (JSON lines) is
// read as rows are fetched, so a LIMIT stops the transfer early.
//
// Columns: time (_time), msg (_msg), stream (_stream), fields (all, as
// JSON), query (the LogsQL query, * by default); any other column is the
// field of that name.

type logRows struct {
	cols  []role
	names []string
	query string
	desc  string
	resp  *http.Response
	rd    *bufio.Reader
}

func scanLogs(t *fdw.Table, r *request) (fdw.Rows, error) {
	query := r.query
	if query == "" {
		query = "*"
	}
	// Field conditions go in extra_filters, so any query (pipes included)
	// is sent unchanged.
	var filters []string
	for _, k := range sortedKeys(r.filters) {
		v := r.filters[k]
		switch k {
		case "_stream":
			// a stream selector; anything else is only checked locally
			if strings.HasPrefix(v, "{") && strings.HasSuffix(v, "}") {
				filters = append(filters, "_stream:"+v)
			}
		default:
			filters = append(filters, strconv.Quote(k)+":="+strconv.Quote(v))
		}
	}
	params := [][2]string{
		{"query", query},
		{"start", r.start.Format(time.RFC3339Nano)},
		{"end", r.end.Format(time.RFC3339Nano)},
	}
	if len(filters) > 0 {
		params = append(params, [2]string{"extra_filters", strings.Join(filters, " AND ")})
	}
	if v, ok := t.Option("limit"); ok {
		params = append(params, [2]string{"limit", v})
	}
	resp, desc, err := r.get(r.base+"/select/logsql/query", params)
	if err != nil {
		return nil, err
	}
	l := &logRows{query: query, desc: desc, resp: resp, rd: bufio.NewReaderSize(resp.Body, 64<<10)}
	for _, c := range t.Columns {
		l.cols = append(l.cols, columnRole(true, c))
		l.names = append(l.names, remoteName(c))
	}
	return l, nil
}

func (l *logRows) Next() ([]any, error) {
	for {
		line, err := l.rd.ReadBytes('\n')
		if len(line) == 0 && errors.Is(err, io.EOF) {
			return nil, nil
		}
		if err != nil && !errors.Is(err, io.EOF) {
			return nil, err
		}
		if len(strings.TrimSpace(string(line))) == 0 {
			continue
		}
		var entry map[string]any
		if err := json.Unmarshal(line, &entry); err != nil {
			return nil, remoteErr("VictoriaLogs: invalid response line: %v", err)
		}
		fields := make(map[string]string, len(entry))
		for k, v := range entry {
			if s, ok := v.(string); ok {
				fields[k] = s
			} else {
				fields[k] = fmt.Sprint(v)
			}
		}
		row := make([]any, len(l.cols))
		for i, r := range l.cols {
			var name string
			switch r {
			case roleTime:
				name = "_time"
			case roleMsg:
				name = "_msg"
			case roleStream:
				name = "_stream"
			case roleFields:
				row[i] = jsonText(fields)
				continue
			case roleQuery:
				row[i] = l.query
				continue
			case roleOther:
				name = l.names[i]
			default:
				continue
			}
			if v, ok := fields[name]; ok {
				row[i] = v
			}
		}
		return row, nil
	}
}

func (l *logRows) Close() error     { return l.resp.Body.Close() }
func (l *logRows) Describe() string { return l.desc }
