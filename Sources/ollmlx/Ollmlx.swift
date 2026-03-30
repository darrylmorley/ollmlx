import ArgumentParser
import OllmlxCore

@main
struct Ollmlx: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ollmlx",
        abstract: "Run local LLMs via mlx-lm on Apple Silicon",
        version: "0.1.0",
        subcommands: [
            Serve.self,
            Run.self,
            Pull.self,
            List.self,
            Show.self,
            Remove.self,
            Stop.self,
            Ps.self,
            Status.self,
        ]
    )
}
