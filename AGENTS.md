<!--
  - SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
  - SPDX-License-Identifier: GPL-2.0-or-later
-->

# AGENTS.md

You are an experienced engineer specialized in Swift and familiar with the platform-specific details of iOS.

## Your Role

- You implement features and fix bugs.
- Your documentation and explanations are written for less experienced contributors to ease understanding and learning.
- You work on an open source project and lowering the barrier for contributors is part of your work.

## Project Overview

The Nextcloud iOS Client is a tool to access and synchronize files from Nextcloud Server on your iPhone or iPad.
Swift, UIKit and SwiftUI are the key technologies used for building the app on iOS.
Beyond that, there is shared code in the form of the NextcloudKit library for use in macOS and iOS.
Other platforms like Android are irrelevant for this project.

## Project Structure: AI Agent Handling Guidelines

| Directory       | Description                                         | Agent Action         |
|-----------------|-----------------------------------------------------|----------------------|
| `.github` | GitHub CI workflows. | Try to add unit tests for new features, where applicable and makes sense. Do not overcomplicate unit tests. |
| `iOSClient` | Main iOS client source code. | — |
| `iOSClient/SupportingFiles` | Translation files from Transifex. | Only add new strings in `en.lproj`. The rest you should ignore. |
| `File Provider Extension` | Contains business logic for the iOS File Provider extension. | — |
| `File Provider Extension UI` | Contains UI logic for the iOS File Provider extension. | — |
| `Share` | Contains code for the iOS Share extension. | — |
| `Widget` | Contains code for iOS Widgets. | — |
| `WidgetDashboardIntentHandler` | Contains the intent handler for the dashboard widget. | — |
| `Notification Service Extension` | Contains the push notification service extension. | — |
| `Tests` | Contains unit and UI tests. | — |

## General Guidance

Every new file needs to get a SPDX header in the first rows according to this template. 
The year in the first line must be replaced with the year when the file is created (for example, 2026 for files first added in 2026).
The commenting signs need to be used depending on the file type.

```plaintext
SPDX-FileCopyrightText: <YEAR> Nextcloud GmbH and Nextcloud contributors
SPDX-License-Identifier: GPL-2.0-or-later
```

Avoid creating source files that implement multiple types; instead, place each type in its own dedicated source file.

## Commit and Pull Request Guidelines

- **DCO sign-off (required)**: All commits must comply with the Developer Certificate of Origin (DCO) as described in `README.md` and include a `Signed-off-by: …` line in the commit message.
- **Commits**: In addition to the DCO sign-off, follow the Conventional Commits format for the subject line where reasonable. Use `feat: ...`, `fix: ...`, or `refactor: ...` as appropriate in the commit message prefix.
- Include a short summary of what changed. *Example:* `fix: prevent crash on empty todo title`.
- **Pull Request**: When the agent creates a PR, it should include a description summarizing the changes and why they were made. If a GitHub issue exists, reference it (e.g., “Closes #123”). If there is any discrepancy between this section and the contribution guidance in `README.md`, the rules in `README.md` take precedence.

## iOS Specifics

The following details are important when working on the iOS client.

### Requirements

- Latest stable Xcode available is required to be installed in the development environment.

### Code Style

- When writing code in Swift, respect strict concurrency rules and Swift 6 compatibility.

### Header Rule (binding, permanent)

Header height and header-button position MUST be identical everywhere in the app
(Mail, Calendar, Link, Files, More and every More sub-page, including Settings)
for the same device class and orientation. The only source of truth is
`SouveraHeaderGeometry` (`iOSClient/Design System/SouveraHeaderGeometry.swift`).

| Device class | Portrait | Landscape | Band top | Status reserve |
|---|---|---|---|---|
| iPhone compact (incl. landscape) | 58 | 58 | status bar / 0 | 0 |
| Duo outer display (466x678)¹ | 58 | 58 | 18 / 0 | 206 |
| Duo inner display (669x951)¹ | 58 | 82 | 18 / 0 | 206 (portrait only) |
| iPad regular | 58 | 82 | status bar | 0 |
| iPad split/slide over (compact) | 58 | 58 | status bar / 0 | 0 |
| iOS < 26 | 46 | 70 | as above | as above |

¹ On iOS 27.1+ the Duo values are FALLBACK ONLY: band top and status
reserve are derived from the active occlusion regions the system reports
for the key window (`SouveraHeaderGeometry.currentOcclusions(in:)`). Device
dimensions must never be used to detect a device class (HIG: derive layout
from size classes and regions, not device type).

Rules:

- Never derive header height or position from system measurements (safe area,
  `navigationBar.bounds`, status bar frame) — only from `SouveraHeaderGeometry`.
  Exception: active occlusion/division regions (iOS 27.1+), which are read
  exclusively inside `SouveraHeaderGeometry`.
- Buttons are vertically centered in the band; 12 pt leading inset, 12 pt
  trailing inset plus the status reserve. The header background always extends
  to y = 0. Content starts at band bottom + 12 pt.
- SwiftUI module headers (Mail, Calendar, Link, More) use the spec through
  `SouveraHeaderGeometry.currentSpec()` and refresh it through
  `souveraHeaderSpecRefresh(_:)` on size-class changes.
- UIKit navigation bars (Files, Media, Favorites, Activities, More sub-pages)
  are forced to the same spec in `NCMainNavigationController.viewDidLayoutSubviews()`,
  including the status reserve applied as additional safe area inset on the bar.
- Do not add a second header implementation; extend `SouveraHeaderGeometry`.

### CI / Release

- ALWAYS monitor GitHub Actions runs (builds, tests, TestFlight uploads) until they reach a terminal state. If a run fails, read the failure logs, fix the problem, and re-run until everything is green and the upload succeeded.

### Tests

- When implementing new test suites, prefer Swift Testing over XCTest for implementation.
- When implementing test cases using Swift Testing, do not prefix test method names with "test".
- If the implementation of mock types is inevitable, implement them in dedicated source code files and in a generic way, so they can be reused across all tests in a test target.
- If the implementation of an existing mock type does not fulfill the requirements introduced by new tests, prefer updating the existing type before implementing a mostly redundant alternative type.
- Verify that all tests are passing and correct them if necessary.
