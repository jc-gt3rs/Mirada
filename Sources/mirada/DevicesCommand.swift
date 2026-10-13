import ArgumentParser
import MiradaKit

struct DevicesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "devices", abstract: "List cameras.")

    @Flag(name: .long, help: "Write JSON to stdout.")
    var json = false

    func run() async throws {
        let devices = CameraDevices.list()
        if json {
            CLI.printJSON(devices)
            return
        }
        if devices.isEmpty {
            CLI.warn("no cameras found")
            throw ExitCode(69)
        }
        for d in devices {
            let tag = d.isVirtual ? "  // virtual, not used as input" : ""
            print("\(d.name)\n  id: \(d.id)\(tag)")
        }
    }
}
