# Third-party licenses

All bundled dependencies use permissive licenses compatible with Apache-2.0.

## Python (CLI, web UI, MCP server, one-file builds)
| Package | License |
|---|---|
| PyMySQL | MIT |
| pg8000 | BSD-3-Clause |
| scramp (pg8000) | MIT-0 |
| asn1crypto (pg8000) | MIT |
| python-dateutil (pg8000) | Apache-2.0 / BSD-3-Clause |
| six | MIT |
| keyring | MIT |
| jaraco.classes, jaraco.context, jaraco.functools, more-itertools (keyring) | MIT |
| typing_extensions | PSF-2.0 |
| CPython runtime (embedded by one-file builds) | PSF-2.0 |

## Swift (native macOS app)
| Package | License |
|---|---|
| postgres-nio, mysql-nio (Vapor) | MIT |
| swift-nio, swift-nio-ssl, swift-nio-transport-services, swift-log, swift-metrics, swift-collections, swift-algorithms, swift-async-algorithms, swift-atomics, swift-numerics, swift-system, swift-asn1, swift-crypto, swift-service-lifecycle (Apple / SSWG) | Apache-2.0 |
| BoringSSL (via swift-nio-ssl / swift-crypto) | OpenSSL / ISC-style |

## System components (not bundled)
SQLite (public domain, macOS system library), OpenSSH client (`ssh`, used for tunnels).
