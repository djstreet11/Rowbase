# Security

Rowbase handles database credentials and runs SQL. Please report vulnerabilities privately (do not open a public issue):
email the maintainers or use the repository's private vulnerability reporting. We aim to respond within 7 days.

Design notes: passwords are stored in the OS keychain (never in config files or logs); the local web UI binds to
127.0.0.1 and rejects foreign Host headers and requests without the `X-Rowbase` header; read-only connections are
enforced at four layers (see SPEC.md §2.1).
