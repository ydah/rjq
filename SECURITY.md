# Security policy

Please report suspected vulnerabilities privately through GitHub's security advisory interface for this repository. Do not open a public issue with exploit details before a fix is available.

Supported releases are the current `main` branch and the latest published gem version.

Security-sensitive boundaries include module path resolution, symlink and traversal checks, incremental JSON parsing, regex resource consumption, cyclic host values, and process capabilities exposed by file, environment, time, and diagnostic builtins.

Current safeguards include canonical module roots, module byte/depth/cycle limits, a 256-level JSON parse limit, cyclic-value rejection, incremental input, optional output budgets, and early file closure. Ruby Regexp can still be exposed to expensive patterns; callers processing untrusted patterns should use process-level time and memory limits.

