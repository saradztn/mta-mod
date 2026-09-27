# DefensiveSourceScan

A small, offline .NET command-line utility for reviewing source code for API indicators commonly associated with input capture, screen capture, network communication, file access, process execution, and persistence.

This is a static indicator scanner, not a behavior monitor or malware classifier. It does not execute scanned files, install hooks, capture input or screens, read files as collected data, create network connections, or transfer data. Findings are heuristic: legitimate software can use these APIs, and obfuscated, dynamically resolved, or otherwise unlisted behavior may not be detected. Review each match in context.

## Requirements

- .NET 8 SDK
- No third-party packages or network access required to build or run

## Build and run

From this directory:

```sh
dotnet build --configuration Release
dotnet run --configuration Release -- ../path/to/source
```

Scan individual source files or directories. Directory scans are recursive by default. Common generated and dependency directories (`.git`, `.vs`, `bin`, `obj`, `node_modules`, `packages`, and `vendor`) are skipped.

```sh
# Scan a project and print a JSON report
dotnet run -- --json ../sample-project

# Scan only the directory's immediate files
dotnet run -- --no-recursive ../sample-project

# Add a directory name to the default exclusion list
dotnet run -- --exclude generated ../sample-project
```

Supported source extensions include C#, C/C++, Java, JavaScript/TypeScript, Go, Rust, Python, PowerShell, Lua, PHP, Ruby, Swift, and Kotlin. Unsupported extensions are ignored.

## Exit codes

- `0`: scan completed with no indicators
- `1`: one or more indicators found
- `2`: input or scan error

## Scope and limitations

The scanner checks each source line independently using a compact set of regular expressions. It can produce false positives and does not perform parsing, data-flow analysis, binary inspection, or runtime monitoring. Treat output as leads for a broader review, not as proof of malicious behavior or safety.
