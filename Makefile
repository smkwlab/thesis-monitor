.PHONY: help deps build install test dialyzer credo clean

BINARY_NAME = thesis-monitor

help:
	@echo "Thesis Monitor - Build Commands"
	@echo ""
	@echo "  make deps      - Install dependencies"
	@echo "  make build     - Build escript binary"
	@echo "  make install   - Install to ~/.mix/escripts"
	@echo "  make test      - Run tests"
	@echo "  make dialyzer  - Run type checking"
	@echo "  make credo     - Run code quality checks"
	@echo "  make clean     - Clean build artifacts"
	@echo ""

deps:
	@echo "Installing dependencies..."
	@mix deps.get

build: deps
	@echo "Building escript..."
	@mix escript.build
	@chmod +x $(BINARY_NAME)
	@echo "Build complete: ./$(BINARY_NAME)"

install: build
	@echo "Installing to ~/.mix/escripts..."
	@mix escript.install --force
	@echo "Installed to ~/.mix/escripts/$(BINARY_NAME)"
	@echo "Note: Add ~/.mix/escripts to your PATH to use '$(BINARY_NAME)' directly"

test:
	@echo "Running tests..."
	@mix test

dialyzer:
	@echo "Running Dialyzer..."
	@mix dialyzer

credo:
	@echo "Running Credo..."
	@mix credo

clean:
	@echo "Cleaning build artifacts..."
	@rm -f $(BINARY_NAME)
	@rm -rf _build/
	@echo "Clean complete"