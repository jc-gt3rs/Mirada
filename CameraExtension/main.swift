@preconcurrency import CoreMediaIO
import Foundation

// Mirada Camera: a CoreMediaIO camera extension with a source stream (what
// video apps read) and a sink stream (what Mirada writes corrected frames
// into). Frames arriving on the sink are forwarded to the source; when none
// arrive, the source shows a "Mirada isn't running" card.
let providerSource = MiradaProviderSource(clientQueue: nil)
CMIOExtensionProvider.startService(provider: providerSource.provider)
CFRunLoopRun()
