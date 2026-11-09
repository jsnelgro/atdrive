import CExtensionMain
import Foundation

// An app extension's executable hands control to Foundation, which connects to the system and
// instantiates the principal class named in Info.plist (`ATDriveFileProviderExtension`).
// Referencing the class keeps the linker from dropping it, since nothing else names it.
_ = FileProviderExtension.self
exit(ATDriveExtensionMain(CommandLine.argc, CommandLine.unsafeArgv))
