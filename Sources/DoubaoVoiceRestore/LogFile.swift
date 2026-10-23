import DoubaoVoiceRestoreCore
import Foundation

/// Keeps the LaunchAgent log from growing without bound.
///
/// launchd appends stdout to one file forever. At startup, if stdout is a
/// regular file over the size limit, it is cut down to its most recent tail.
///
/// launchd opens the file write-only in append mode, so the tail is read
/// through a separate handle on the same path; after truncation, appends on
/// stdout land at the new end automatically.
enum LogFile {
    static func trimIfNeeded() {
        var info = stat()
        guard fstat(STDOUT_FILENO, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
            info.st_size > Tuning.logMaxBytes,
            let path = path(of: STDOUT_FILENO),
            let reader = FileHandle(forReadingAtPath: path)
        else { return }
        defer { try? reader.close() }

        do {
            try reader.seek(toOffset: UInt64(info.st_size - Tuning.logKeepBytes))
            var tail = try reader.readToEnd() ?? Data()
            // Drop the partial first line.
            if let newline = tail.firstIndex(of: UInt8(ascii: "\n")) {
                tail = tail[tail.index(after: newline)...]
            }
            guard ftruncate(STDOUT_FILENO, 0) == 0 else { return }
            let stdout = FileHandle(fileDescriptor: STDOUT_FILENO, closeOnDealloc: false)
            stdout.write(tail)
            stdout.write(Data("--- log trimmed to its last \(tail.count) bytes ---\n".utf8))
        } catch {
            // An unreadable log is not worth failing over.
        }
    }

    private static func path(of descriptor: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(descriptor, F_GETPATH, &buffer) != -1 else { return nil }
        return String(cString: buffer)
    }
}
