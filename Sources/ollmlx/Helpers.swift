import Foundation

/// Print to stderr for error messages.
func printError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}
