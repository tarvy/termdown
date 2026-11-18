import Foundation
import TermDownCore
import TermDownHost

func fail(_ message: String, status: Int32) -> Never {
  FileHandle.standardError.write(Data((message + "\n").utf8))
  exit(status)
}

let arguments = Array(CommandLine.arguments.dropFirst())

switch arguments.first {
case nil, "--help", "-h":
  print(commandUsage)
case "-v", "--version":
  print("termdown \(termDownVersion)")
case "open":
  switch OpenArguments.parse(Array(arguments.dropFirst())) {
  case .success(let open): OpenCommand.run(open)
  case .failure(let error): fail(error.description, status: 64)
  }
case "edit":
  EditCommand.run(Array(arguments.dropFirst()))
case "review":
  ReviewCommand.run(Array(arguments.dropFirst()))
case "config":
  ConfigCommand.run(Array(arguments.dropFirst()))
case "setup":
  await SetupCommand.setup()
case "uninstall":
  await SetupCommand.uninstall()
case "agents":
  AgentsCommand.run(Array(arguments.dropFirst()))
case "claude":
  ClaudeCommand.run(Array(arguments.dropFirst()))
case "agent-guide":
  switch arguments.count > 1 ? arguments[1] : nil {
  case nil: print(agentGuide, terminator: "")
  case "review": print(reviewGuide(), terminator: "")
  case let topic?:
    fail("unknown topic: \(topic)\nusage: termdown agent-guide [\(agentGuideTopics.joined(separator: "|"))]", status: 64)
  }
case "doctor":
  DoctorCommand.run()
case "view":
  guard let view = ViewArguments(Array(arguments.dropFirst())) else {
    fail("usage: termdown view [--theme-source-block <block>] [--opener-block <block>] <file>", status: 64)
  }
  await ViewCommand.run(view)
case SVGRenderProcess.command:
  exit(SVGRenderProcess.serve(arguments: Array(arguments.dropFirst())))
case let command?:
  fail("unknown command: \(command)\n\n\(commandUsage)", status: 64)
}
