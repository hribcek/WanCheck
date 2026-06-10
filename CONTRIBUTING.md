# Contributing to WanMoth

Thank you for your interest in contributing to WanMoth! We welcome contributions from the community to help improve this ASUS router utility.

## Getting Started

1. Fork the repository
2. Clone your fork locally
3. Create a feature branch: `git checkout -b feature/your-feature-name`
4. Make your changes
5. Test thoroughly on your ASUS router with Merlin firmware
6. Commit with clear messages: `git commit -am 'Add feature description'`
7. Push to your fork: `git push origin feature/your-feature-name`
8. Submit a Pull Request with a detailed description

## Development Guidelines

### Shell Script Standards
- Use POSIX-compatible shell syntax (ash/sh compatible for ASUS routers)
- Run scripts through ShellCheck: `shellcheck script.sh`
- Follow the existing code style and formatting
- Add comments for complex logic
- Test on actual ASUS Merlin firmware when possible

### Commit Messages
- Start with a verb in present tense: "Add", "Fix", "Update", "Remove"
- Keep the first line under 50 characters
- Add detailed explanation in the body if needed

### Testing
- Run the test suite before opening a PR: `sh tests/test_wanmoth.sh` (all tests must pass)
- Lint changed scripts: `shellcheck wanmoth install.sh tests/test_wanmoth.sh`
- Test on multiple ASUS router models if possible
- Verify scripts work with Merlin firmware
- Document any router-specific requirements

## Releasing

This project uses [Semantic Versioning](https://semver.org/) and annotated git
tags (`vMAJOR.MINOR.PATCH`). The version lives in two places that **must stay in
sync** — `WANMOTH_VERSION` in [`wanmoth`](wanmoth) and the latest release heading
in [`CHANGELOG.md`](CHANGELOG.md). Test 19 in the suite fails if they diverge.

To cut a release (example: `0.3.0`):

1. Bump `WANMOTH_VERSION="0.3.0"` in `wanmoth`.
2. Add a `## [0.3.0] - YYYY-MM-DD` heading in `CHANGELOG.md` and move the
   relevant notes under it (Added / Changed / Removed).
3. Verify: `sh tests/test_wanmoth.sh` passes and `shellcheck wanmoth install.sh`
   is clean. Confirm the script reports the new version: `sh wanmoth --version`.
4. Commit (e.g. `chore: release v0.3.0`) and push `master`.
5. Tag and push:
   ```bash
   git tag -a v0.3.0 -m "WanMoth 0.3.0 — <one-line summary>"
   git push origin master --follow-tags
   ```

## Code of Conduct

- Be respectful and constructive in all interactions
- Provide helpful feedback to other contributors
- Report security issues privately
- No spam, harassment, or discrimination

## Questions?

Feel free to open an issue for questions or discussions about the project.

Thank you for contributing!
