# Contributing to Blob

Thanks for your interest in improving Blob. It is a small, focused project, and contributions that keep it that way are very welcome.

## Getting started

Requirements: macOS 14 or later and a Swift 5.9 toolchain (Xcode 15+).

```bash
git clone https://github.com/w3debugger/blob.git
cd blob
swift run Blob        # quick dev loop
```

Or open `Blob.xcodeproj` and press Run. For signing, pick your own team under the Blob target, Signing and Capabilities (the committed project leaves the team blank on purpose).

## Guidelines

- **Keep it lean.** Blob has three modes by design. A new option needs to solve a problem most users actually hit, not just add surface area.
- **Files go to the Trash.** Anything that removes files must use `FileManager.trashItem`, never an unrecoverable delete, and must show the full path before acting.
- **Match the surrounding style.** SwiftUI views are small and composable; scanning logic lives in `FileScanner`.
- **Run it, do not just build it.** Verify your change by launching the app and exercising the affected mode.

## Submitting a pull request

1. Fork and create a branch off `main`.
2. Make your change with a clear, focused commit history.
3. Describe what changed and why. Screenshots help for UI changes.
4. Open the PR against `main`.

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
