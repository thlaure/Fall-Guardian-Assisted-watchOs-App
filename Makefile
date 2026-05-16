.PHONY: help analyze test build check clean

.DEFAULT_GOAL := help

PROJECT := FallGuardian/FallGuardian.xcodeproj
SCHEME := FallGuardian Watch App
DESTINATION ?= platform=watchOS Simulator,name=Apple Watch Series 10 (46mm)

help: ## Show available commands
	@echo "Fall Guardian watchOS app"
	@echo ""
	@grep -E '(^[a-zA-Z_-]+:.*?##.*$$)' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-14s %s\n", $$1, $$2}'

test: ## Run watchOS tests on the configured simulator
	xcodebuild -project "$(PROJECT)" -scheme "$(SCHEME)" -destination "$(DESTINATION)" test

analyze: ## Run Xcode static analyzer
	xcodebuild -project "$(PROJECT)" -scheme "$(SCHEME)" -destination "$(DESTINATION)" analyze

build: ## Build the watchOS app on the configured simulator
	xcodebuild -project "$(PROJECT)" -scheme "$(SCHEME)" -destination "$(DESTINATION)" build

check: analyze test build ## Run deterministic quality checks

clean: ## Clean Xcode build artifacts
	xcodebuild -project "$(PROJECT)" -scheme "$(SCHEME)" clean
