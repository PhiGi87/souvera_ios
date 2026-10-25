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

There is exactly ONE header implementation for the whole app: the system
`UINavigationBar` of the containing navigation controller. This applies to
Mail, Calendar, Link, Files, Media, Favorites, Activities, More, every More
sub-page (including Settings) and every pushed screen.

- Never build a custom header (no `SouveraModuleHeader`, no custom
  `UINavigationBar`/`UIToolbar`/`UITabBar`, no header `safeAreaInset`).
  Custom bars are not presented vertically by the system on iPhone Duo and
  cannot adapt to reserved regions.
- Appearance comes exclusively from `SouveraAppearance.applyBlueNavigationBar`
  (gradient, opaque, light). Do not set per-screen bar appearances.
- Items come exclusively from standard `UIBarButtonItem`s built by
  `SouveraHeaderBridge` / `SouveraBarCoordinator`: image and/or title, real
  `UIMenu`s, `isPinned` for the module's primary action
  (`UINavigationItem.pinnedTrailingGroup`), never custom views in bars.
- Do not force bar geometry: no frame overrides, no additional safe-area
  insets, no reserved-region math, no manual header paddings in content.
  Height, position, orientation (vertical bars on the Duo outer display) and
  safe-area handling are owned by UIKit.
- Content relies on safe areas only; the single source for split/navigation
  decisions is `SouveraLayoutMode` (`isRegularWidth`).
- Content/title may differ per screen (that is content, not layout); the
  foundation must stay identical.

### CI / Release

- ALWAYS monitor GitHub Actions runs (builds, tests, TestFlight uploads) until they reach a terminal state. If a run fails, read the failure logs, fix the problem, and re-run until everything is green and the upload succeeded.

### Tests

- When implementing new test suites, prefer Swift Testing over XCTest for implementation.
- When implementing test cases using Swift Testing, do not prefix test method names with "test".
- If the implementation of mock types is inevitable, implement them in dedicated source code files and in a generic way, so they can be reused across all tests in a test target.
- If the implementation of an existing mock type does not fulfill the requirements introduced by new tests, prefer updating the existing type before implementing a mostly redundant alternative type.
- Verify that all tests are passing and correct them if necessary.
