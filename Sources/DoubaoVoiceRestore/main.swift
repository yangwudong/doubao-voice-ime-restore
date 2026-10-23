import Foundation

let programName = "DoubaoVoiceRestore"
let programVersion = "1.2.0"

func printUsage(to stream: FileHandle = .standardOutput) {
    let usage = """
        \(programName) \(programVersion)
        Keeps your own input method selected after Doubao IME's global voice input.

        USAGE
          \(programName) [options]

        OPTIONS
          -q, --quiet      Do not log activity
          --verbose        Also log every input-source change (default: state transitions only)
          --self-check     Exercise the system APIs this tool relies on, then exit
          -h, --help       Show this help and exit
          -v, --version    Show the version and exit

        Runs in the foreground until interrupted. It is normally installed as a
        LaunchAgent by scripts/install.sh, which logs to
        ~/Library/Logs/\(programName).log.

        """
    stream.write(Data(usage.utf8))
}

var isQuiet = false
var isVerbose = false

for argument in CommandLine.arguments.dropFirst() {
    switch argument {
    case "-q", "--quiet":
        isQuiet = true
    case "--verbose":
        isVerbose = true
    case "--self-check":
        exit(SelfCheck.run())
    case "-h", "--help":
        printUsage()
        exit(EXIT_SUCCESS)
    case "-v", "--version":
        print("\(programName) \(programVersion)")
        exit(EXIT_SUCCESS)
    default:
        FileHandle.standardError.write(
            Data("\(programName): unknown option '\(argument)'\n\n".utf8))
        printUsage(to: .standardError)
        exit(64)  // EX_USAGE
    }
}

LogFile.trimIfNeeded()

// Held by a global so the run loop's weak captures stay valid for the
// lifetime of the process.
let watchdog = Watchdog(isQuiet: isQuiet, isVerbose: isVerbose)
watchdog.run()
