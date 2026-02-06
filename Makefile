.PHONY: help init install-pre-commit security lint format check format-fix clean check-docker

# Default target
help:
	@echo "Available targets:"
	@echo "  make init          - Install pre-commit hooks"
	@echo "  make security      - Run security scans (Trivy + Gitleaks)"
	@echo "  make lint          - Run ShellCheck linting"
	@echo "  make format        - Check shell script formatting"
	@echo "  make format-fix    - Auto-fix shell script formatting"
	@echo "  make check         - Run all checks (security + lint + format)"
	@echo "  make clean         - Remove temporary files"

# Variables
SHELL_SCRIPTS := install.sh
DOCKER_RUN := docker run --rm -v "$(CURDIR):/workspace" -w /workspace
TRIVY_IMAGE := aquasec/trivy:latest
GITLEAKS_IMAGE := zricethezav/gitleaks
SHELLCHECK_IMAGE := koalaman/shellcheck
SHFMT_IMAGE := mvdan/shfmt:v3.7.0

# Initialize pre-commit hooks
init: install-pre-commit
	@echo "✓ Pre-commit hooks installed"

install-pre-commit:
	@command -v pre-commit >/dev/null 2>&1 || { \
		echo "Error: pre-commit is not installed. Install it with:"; \
		echo "  pip install pre-commit"; \
		echo "  or"; \
		echo "  brew install pre-commit"; \
		exit 1; \
	}
	@pre-commit install --hook-type commit-msg
	@echo "✓ Pre-commit hooks installed successfully"

# Check Docker availability
check-docker:
	@command -v docker >/dev/null 2>&1 || { \
		echo "Error: Docker is not installed or not running."; \
		echo "Please install Docker: https://docs.docker.com/get-docker/"; \
		exit 1; \
	}

# Security scanning
security: check-docker security-trivy security-gitleaks
	@echo "✓ All security scans completed"

security-trivy: check-docker
	@echo "Running Trivy vulnerability scan..."
	@echo "Pulling Trivy image if needed..."
	@docker pull $(TRIVY_IMAGE) >/dev/null 2>&1 || true
	@$(DOCKER_RUN) $(TRIVY_IMAGE) \
		fs --severity CRITICAL,HIGH --exit-code 1 --no-progress /workspace || true
	@echo "✓ Trivy scan completed"

security-gitleaks: check-docker
	@echo "Running Gitleaks secret detection..."
	@$(DOCKER_RUN) $(GITLEAKS_IMAGE) \
		detect --source /workspace --verbose --no-banner || true
	@echo "✓ Gitleaks scan completed"

# Linting
lint: check-docker
	@echo "Running ShellCheck linting..."
	@$(DOCKER_RUN) $(SHELLCHECK_IMAGE) \
		--severity=warning $(SHELL_SCRIPTS)
	@echo "✓ Linting completed"

# Formatting
format: check-docker
	@echo "Checking shell script formatting..."
	@$(DOCKER_RUN) $(SHFMT_IMAGE) \
		-d -i 2 -ci -sr $(SHELL_SCRIPTS) || { \
		echo "::error::Shell scripts are not properly formatted. Run 'make format-fix' to fix."; \
		exit 1; \
	}
	@echo "✓ Format check passed"

format-fix: check-docker
	@echo "Fixing shell script formatting..."
	@$(DOCKER_RUN) $(SHFMT_IMAGE) \
		-w -i 2 -ci -sr $(SHELL_SCRIPTS)
	@echo "✓ Formatting applied"

# Run all checks
check: security lint format
	@echo "✓ All checks passed"

# Cleanup
clean:
	@echo "Cleaning temporary files..."
	@rm -f trivy-results.sarif .gitleaks-report.json
	@echo "✓ Cleanup completed"
