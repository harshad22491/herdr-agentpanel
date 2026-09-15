# Provenance and downstream changes

Original project: https://github.com/alexarthurs/herdr-sidebar
Original author: Alex Arthurs
License: MIT; the unmodified upstream notice is in LICENSE.
Base commit: 13ebde8d631494f1273d8c5e3503a755047c1267
Base version: 0.10.0

This subtree is a source snapshot, not a claim that the original project's Git
history belongs to herdr-agentpanel. The parent repository's dashboard scripts
remain unchanged.

## Changes on 2026-09-15

- On Windows, use Herdr's pane cwd when foreground_cwd is unavailable. Herdr's
  integrated PowerShell prompt updates cwd after Set-Location (OSC 9;9).
- Ignore agentpanel utility panes when choosing the project directory.
- Prefer the working pane's directory over a folder remembered by space name
  when following is enabled. Reusing a space label cannot select a stale project.
- Retain the current root when switching between Files and Git.
- Remove the incorrect Windows "host n/a" label for folder following.
- Preserve manual overrides and the pause while editing Git commit drafts.
- Fetch matching release assets only from harshad22491/herdr-agentpanel, falling
  back to source builds. Never replace the fix with an upstream release binary.

Runtime changes are limited to src/launch.rs, src/main.rs, and src/state.rs.
The remaining upstream crate, launch scripts, and images are retained.

## Verification

The patched source passed 193 library tests, 17 UI tests, and Clippy with
warnings denied on Windows. Live checks verified independent files, branches,
and remotes in two same-named spaces and automatic updates after a directory
change. Existing user settings and agent/preview panes were preserved.

The local validation build used Rust 1.98.1, the Windows GNU toolchain,
LLVM-MinGW's llvm-dlltool, and Rust's bundled rust-lld, with one build job and
debug information disabled due to available memory. That toolchain needed
RUSTC_BOOTSTRAP=1 for a dependency's macro path and explicit GNU-LLD linking.
Those machine-specific workarounds are not required by the plugin manifest
and are not installed globally. No prebuilt binary is included in Git.

## Source switch and rollback

The plugin ID, event hooks, and state-directory format are unchanged. A built
checkout can replace the registration with `herdr plugin link <plugin-directory>`.
Existing live panels can keep running the already-tested equivalent executable;
new launches use the linked checkout. Keep the prior checkout and binaries.
To roll back registration, link the prior plugin directory again. Do not kill
the Herdr server or remove user state. Quit sidebar panels gracefully before
relaunching if a binary change is needed, to preserve commit-message drafts.
