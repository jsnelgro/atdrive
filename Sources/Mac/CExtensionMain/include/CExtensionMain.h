#pragma once

/// Foundation's entry point for app extensions. Xcode links extensions with
/// `-e _NSExtensionMain`; we build with SwiftPM instead, so `main.swift` calls it directly.
/// It sets up the connection to the system and never returns while the extension runs.
int ATDriveExtensionMain(int argc, char *_Nullable *_Nonnull argv) __asm("_NSExtensionMain");
