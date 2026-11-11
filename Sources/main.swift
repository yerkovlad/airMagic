import AppKit

// One executable, three modes:
//   airMagic                  the menu bar app
//   airMagic --link ADDRESS   the Bluetooth child process the app starts
//   airMagic --self-test      offline checks (no AirPods needed)

let args = CommandLine.arguments
if args.count == 2 && args[1] == "--self-test" {
    exit(SelfTest.run())
}
if args.count == 3 && args[1] == "--link" {
    exit(Link.run(address: args[2]))
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
