// The guest agent of the virtual machines (docs/virtual-machines.md › Guest agent). It runs in the
// account's graphical session of a guest, as a LaunchAgent, connects to the host over virtio-vsock
// and answers the host's requests. `scripts/build-app.sh` compiles this folder on its own for
// Apple silicon and macOS 12.0: the sources use no package and nothing newer without a check.
import Darwin
import Foundation

if CommandLine.arguments.dropFirst().contains("--version") {
    print(AgentInfo.version)
    exit(0)
}

// A host that goes away must not end the agent with SIGPIPE. The commands of `exec` get the
// signal's default action back.
signal(SIGPIPE, SIG_IGN)
// The commands of `exec` run in the account's home folder.
_ = chdir(NSHomeDirectory())
// A guest whose display sleeps shows black screenshots, then locks its screen.
AgentPower.keepAwake()

// The connection runs on its own thread; the main thread serves the main queue, which the
// keyboard layout calls need.
let connection = Thread {
    AgentConnector.run()
}
connection.name = "host-connection"
// The JSON of a deep Accessibility tree needs more than the 512 KB of a secondary thread.
connection.stackSize = 8 << 20
connection.start()
RunLoop.main.run()
