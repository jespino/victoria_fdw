# victoria_fdw is built with gopgext (../gopgext).
#
#   make [PG_CONFIG=...]            build victoria_fdw.so, .control, .sql
#   make install [PG_CONFIG=...]    build and install into PostgreSQL
#   make test [PG_CONFIG=...]       integration tests against the playgrounds

PG_CONFIG ?= pg_config
GOPGEXT ?= $(shell command -v gopgext || echo ../gopgext/gopgext)
COMMENT = Foreign data wrapper for VictoriaMetrics and VictoriaLogs

.PHONY: all install test clean
all:
	$(GOPGEXT) build -pg-config $(PG_CONFIG) -comment '$(COMMENT)' .

install:
	$(GOPGEXT) install -pg-config $(PG_CONFIG) -comment '$(COMMENT)' .

test:
	GOPGEXT=$(GOPGEXT) sh test/run.sh $(PG_CONFIG)

clean:
	rm -rf *.so *.control victoria_fdw--*.sql _pgtest
