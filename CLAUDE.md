# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

ClaudeDesk is a macOS SwiftUI application built with Xcode. As of the initial commit it is the unmodified Xcode "App + SwiftData" template — a `NavigationSplitView` listing `Item` records (a single-field `@Model` with a `timestamp`) persisted via a `ModelContainer` configured in `ClaudeDeskApp`. There is no custom architecture yet; expect to introduce structure (view models, services, etc.) as features are added rather than retrofitting onto existing patterns.

- Platform: macOS only (`SDKROOT = macosx`, `MACOSX_DEPLOYMENT_TARGET = 26.3`)
- Language: Swift 5.0
- UI: SwiftUI
- Persistence: SwiftData (`@Model`, `ModelContainer`, `@Query`, `modelContext`)

## Targets and test frameworks

Three targets live in `ClaudeDesk.xcodeproj`:

- `ClaudeDesk` — the app (sources in `ClaudeDesk/`)
- `ClaudeDeskTests` — unit tests, uses **Swift Testing** (`import Testing`, `@Test`, `#expect`), not XCTest
- `ClaudeDeskUITests` — UI tests, uses **XCTest** (`XCUIApplication`)

When adding tests, match the framework already used by that target — don't mix Swift Testing and XCTest in the same target.

## Build and test

There is no workspace and no Swift Package — everything goes through the `.xcodeproj`. Common commands:

```sh
# Build the app
xcodebuild -project ClaudeDesk.xcodeproj -scheme ClaudeDesk -configuration Debug build

# Run all unit + UI tests on the host Mac
xcodebuild -project ClaudeDesk.xcodeproj -scheme ClaudeDesk -destination 'platform=macOS' test

# Run only one test target
xcodebuild -project ClaudeDesk.xcodeproj -scheme ClaudeDesk -destination 'platform=macOS' \
  -only-testing:ClaudeDeskTests test

# Run a single test (Swift Testing uses Target/Suite/testName)
xcodebuild -project ClaudeDesk.xcodeproj -scheme ClaudeDesk -destination 'platform=macOS' \
  -only-testing:ClaudeDeskTests/ClaudeDeskTests/example test
```

The scheme `ClaudeDesk` is auto-generated (user scheme under `xcuserdata/`); if `xcodebuild -list` reports no schemes, open the project in Xcode once or share the scheme via *Product → Scheme → Manage Schemes…*.
