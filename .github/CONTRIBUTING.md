# Contributing to bootstrap-infisical

## Pre-commit Hooks

This repository uses pre-commit hooks to ensure code quality and commit message standards.

### Setup

1. Install pre-commit:
   ```bash
   pip install pre-commit
   # or
   brew install pre-commit
   ```

2. Install the hooks:
   ```bash
   pre-commit install --hook-type commit-msg
   ```

### What the hooks do

- **Conventional Commits**: Validates that commit messages follow the [Conventional Commits](https://www.conventionalcommits.org/) specification
- **ShellCheck**: Lints shell scripts for common errors and best practices
- **shfmt**: Automatically formats shell scripts for consistency

### Commit Message Format

Commit messages must follow the Conventional Commits format:

```
<type>(<scope>): <description>

[optional body]

[optional footer(s)]
```

Examples:
- `feat: add support for custom backup retention`
- `fix(nginx): correct TLS certificate path`
- `docs: update installation instructions`
- `chore: update docker image versions`

## Pull Request Checks

When you open a pull request, GitHub Actions will automatically run:

1. **Security Scans**
   - Trivy vulnerability scanner
   - Gitleaks secret detection

2. **Linting**
   - ShellCheck analysis of all shell scripts

3. **Formatting**
   - Verifies shell scripts are properly formatted with shfmt

All checks must pass before a PR can be merged.

## Releases

Releases are automatically created when code is merged to `main` or `master` branch. The release version is extracted from the merge commit message or generated automatically.
