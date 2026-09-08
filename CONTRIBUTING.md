# Contributing to func-pwsh-sp-cba

Thank you for your interest in contributing! This project makes SharePoint Online PowerShell accessible via HTTP API, and we welcome contributions that improve usability, reliability, and documentation.

## How to Contribute

### Reporting Issues

- **Bug reports**: Include your environment (Docker version, OS), the request body you sent (redact secrets!), and the full error response.
- **Feature requests**: Describe the SharePoint operation you're trying to automate and why the current API doesn't support it.

### Pull Requests

1. **Fork** the repository and create a branch from `main`
2. **Make your changes** — keep PRs focused on a single concern
3. **Test locally** with Docker:
   ```bash
   docker build -t pwsh-sp-cba .
   docker run -p 8080:80 --env-file .env pwsh-sp-cba
   curl http://localhost:8080/api/HealthCheck
   ```
4. **Update documentation** if you're adding/changing API behavior
5. **Submit the PR** with a clear description of what changed and why

### Code Style

- PowerShell scripts should follow the [PowerShell Practice and Style Guide](https://poshcode.gitbook.io/powershell-practice-and-style/)
- Use `Write-Host` for informational logging, `Write-Error` for errors
- Always return structured JSON responses from Azure Function endpoints
- Include error handling with `try/catch` blocks

### Adding New Endpoints

If you're adding a new Azure Function endpoint:

1. Create a new directory under the project root (e.g., `MyFunction/`)
2. Add `function.json` with appropriate HTTP trigger bindings
3. Add `run.ps1` with structured JSON error responses (follow the pattern in `GenerateToken/run.ps1`)
4. Update `README.md` and `docs/` with the new endpoint documentation
5. Add examples to `examples/curl-examples.sh` and `examples/powershell-client.ps1`

### Adding Use Case Examples

We especially welcome contributions to `examples/common-scripts.json` and `docs/USE-CASES.md`. If you've used this API to solve a SharePoint admin problem, please share the script!

## Development Setup

See [docs/QUICKSTART.md](docs/QUICKSTART.md) for local development instructions.

## License

By contributing, you agree that your contributions will be licensed under the [MIT License](LICENSE).
