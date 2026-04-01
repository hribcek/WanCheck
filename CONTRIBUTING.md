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
- Test on multiple ASUS router models if possible
- Verify scripts work with Merlin firmware
- Document any router-specific requirements

## Code of Conduct

- Be respectful and constructive in all interactions
- Provide helpful feedback to other contributors
- Report security issues privately
- No spam, harassment, or discrimination

## Questions?

Feel free to open an issue for questions or discussions about the project.

Thank you for contributing!
