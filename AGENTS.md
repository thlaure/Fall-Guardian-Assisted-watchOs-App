# Agent Guide

This repository contains the Fall Guardian native watchOS app.

Also follow the workspace-level guide at `../AGENTS.md` when working from the parent folder.

`CLAUDE.md` must stay a thin pointer to this file.

## Project

- Native watchOS app for fall detection and watch-side alert handling
- Keep sensor/fall detection code explicit and testable
- Keep phone communication boundaries narrow and easy to review

## Engineering Rules

Always:

- keep watch-to-phone contracts aligned with the assisted app
- keep Xcode build artifacts, user data, derived data, and local signing files out of Git
- prefer readable, explicit code over clever Swift/watchOS platform tricks
- add concise comments for watchOS concepts, sensors, extended runtime, WatchConnectivity, permissions, background delivery, and safety-critical alert behavior when they are not obvious to a non-mobile developer
- keep automated line coverage at or above 90%; coverage must come from useful behavior, contract, edge-case, and regression tests, not shallow line execution
- run relevant Xcode build/tests after Swift or project configuration changes when feasible

Ask first:

- adding Swift packages
- changing bundle IDs, signing, capabilities, entitlements, sensors, or deployment targets
- changing fall detection thresholds or alert handoff behavior

Never:

- hardcode API secrets, tokens, or local machine paths
- hide important fall-detection workflow in SwiftUI view entrypoints

## Verification

Common command shape:

```sh
make check
```

`make check` requires a compatible watchOS simulator/runtime for the configured destination.
