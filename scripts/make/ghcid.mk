# ghcid gets its own cache
GHCID_FLAGS = --builddir ./dist-newstyle/repl --repl-option -O0 --repl-option -fobject-code
GHCID_TESTS_FLAGS = --builddir ./dist-newstyle/repl-tests --repl-option -O0

PANE_WIDTH = $(shell tmux display -p "\#{pane_width}" || echo 80)
PANE_HEIGHT = $(shell tmux display -p "\#{pane_height}" || echo 30 )

# once ghcid's window errors are fixed we can remove this explicit width/height
# nonsense
# this needs to make it into ghcid: https://github.com/biegunka/terminal-size/pull/16
define run_ghcid_api_tests
	@if [[ $$(uname -p) == 'arm' ]]; then \
		HASURA_TEST_BACKEND_TYPE="$(2)" ghcid -c "DYLD_LIBRARY_PATH=$$DYLD_LIBRARY_PATH cabal repl $(1) $(GHCID_TESTS_FLAGS)" \
			--test "main" \
			--width=$(PANE_WIDTH) \
			--height=$(PANE_HEIGHT); \
	else \
  	HASURA_TEST_BACKEND_TYPE="$(2)" ghcid -c "cabal repl $(1) $(GHCID_TESTS_FLAGS)" \
  		--test "main"; \
	fi
endef

define run_ghcid_main_tests
	@if [[ $$(uname -p) == 'arm' ]]; then \
		HASURA_TEST_BACKEND_TYPE="$(3)" ghcid -c "DYLD_LIBRARY_PATH=$$DYLD_LIBRARY_PATH cabal repl $(1) $(GHCID_TESTS_FLAGS)" \
			--test "main" \
			--setup ":set args $(2)" \
			--width=$(PANE_WIDTH) \
			--height=$(PANE_HEIGHT); \
	else \
  	HASURA_TEST_BACKEND_TYPE="$(3)" ghcid -c "cabal repl $(1) $(GHCID_TESTS_FLAGS)" \
  		--test "main" \
			--setup ":set args $(2)"; \
	fi
endef


define run_ghcid
	@if [[ $$(uname -p) == 'arm' ]]; then \
		ghcid -c "cabal repl $(1) $(GHCID_FLAGS)" --width=$(PANE_WIDTH) --height=$(PANE_HEIGHT); \
	else \
  	ghcid -c "cabal repl $(1) $(GHCID_FLAGS)"; \
	fi
endef

.PHONY: ghcid-library
## ghcid-library: build and watch library in ghcid
ghcid-library:
	$(call run_ghcid,graphql-engine:lib:graphql-engine)

.PHONY: ghcid-tests
## ghcid-tests: build and watch main tests in ghcid
ghcid-tests:
	$(call run_ghcid,graphql-engine:test:graphql-engine-tests)

.PHONY: ghcid-api-tests
## ghcid-api-tests: build and watch api-tests in ghcid
ghcid-api-tests:
	$(call run_ghcid,api-tests:exe:api-tests)

.PHONY: ghcid-test-harness
## ghcid-test-harness: build and watch test-harness in ghcid
ghcid-test-harness:
	$(call run_ghcid,test-harness)

.PHONY: ghcid-test-backends
## ghcid-test-backends: run all api tests in ghcid
ghcid-test-backends: start-backends remove-tix-file
	$(call run_ghcid_api_tests,api-tests:exe:api-tests)

.PHONY: ghcid-test-bigquery
## ghcid-test-bigquery: run tests for BigQuery backend in ghcid
# will require some setup detailed here: https://github.com/hasura/graphql-engine-mono/tree/main/server/lib/api-tests#required-setup-for-bigquery-tests
ghcid-test-bigquery: remove-tix-file
	docker compose up -d --wait postgres
	$(call run_ghcid_api_tests,api-tests:exe:api-tests,BigQuery)

.PHONY: ghcid-test-sqlserver
## ghcid-test-sqlserver: run tests for SQL Server backend in ghcid
ghcid-test-sqlserver: remove-tix-file
	docker compose up -d --wait postgres sqlserver{,-healthcheck,-init}
	$(call run_ghcid_api_tests,api-tests:exe:api-tests,SQLServer)

.PHONY: ghcid-test-citus
## ghcid-test-citus: run tests for Citus backend in ghcid
ghcid-test-citus: remove-tix-file
	docker compose -d --wait postgres citus
	$(call run_ghcid_api_tests,api-tests:exe:api-tests,Citus)

.PHONY: ghcid-test-cockroach
## ghcid-test-cockroach: run tests for Cockroach backend in ghcid
ghcid-test-cockroach: remove-tix-file
	docker compose up -d --wait postgres cockroach
	$(call run_ghcid_api_tests,api-tests:exe:api-tests,Cockroach)

.PHONY: ghcid-test-data-connectors
## ghcid-test-data-connectors: run tests for DataConnectors in ghcid
ghcid-test-data-connectors: remove-tix-file
	docker compose build
	docker compose up -d --wait postgres dc-reference-agent dc-sqlite-agent
	$(call run_ghcid_api_tests,api-tests:exe:api-tests,DataConnector)

.PHONY: ghcid-library-pro
## ghcid-library-pro: build and watch pro library in ghcid
ghcid-library-pro:
	$(call run_ghcid,graphql-engine-pro:lib:graphql-engine-pro)

.PHONY: ghcid-test-unit
## ghcid-test-unit: build and run unit tests in ghcid
ghcid-test-unit: remove-tix-file
	$(call run_ghcid_main_tests,graphql-engine:graphql-engine-tests,unit)
