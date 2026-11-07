import LoamCore
import Foundation
import NoteGraphPlugin
import PluginKit
import TasksPlugin
import TruffleSearchPlugin

// Times the work that scales with the vault, on a big generated one (`make perf`, docs/PERF.md).
// Usage: LoamBench VAULT [--runs N] [--no-budget]
// Prints one line per measure (first run, then the median of the next ones) and exits 1 when a median is over its
// budget: the budgets are what a keystroke or a note switch can afford on the main thread, or a launch in the
// background.

let args = CommandLine.arguments.dropFirst()
guard let path = args.first else {
    FileHandle.standardError.write("usage: LoamBench VAULT [--runs N] [--no-budget]\n".data(using: .utf8)!)
    exit(2)
}
let runs = args.firstIndex(of: "--runs").flatMap { Int(args[args.index(after: $0)]) } ?? 5
let checkBudgets = !args.contains("--no-budget")
let vault = Vault(rootURL: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))

func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e6 }

var failures: [String] = []

/// Runs `body` once (first) then `runs` more times (median), and checks the median against `budget` (ms).
func measure(_ name: String, budget: Double, _ body: () throws -> Void) rethrows {
    var times: [Double] = []
    for _ in 0...runs {
        let start = now()
        try body()
        times.append(now() - start)
    }
    let first = times.removeFirst()
    let median = times.sorted()[times.count / 2]
    let over = median > budget
    if over { failures.append(name) }
    let numbers = String(format: "first %8.1f ms   median %8.1f ms   budget %6.0f ms  ", first, median, budget)
    print(name.padding(toLength: 36, withPad: " ", startingAt: 0) + numbers + (over ? "OVER" : "ok"))
}

let stamps = try vault.stamps()
let notes = stamps.keys.filter { $0.hasSuffix(".md") }.sorted()
print("Vault: \(vault.rootURL.path), \(notes.count) notes, \(runs) runs per measure\n")

// Every vault change walks the tree at least once (FileWatcher → refreshVault).
try measure("walk: stamps()", budget: 250) { _ = try vault.stamps() }
try measure("walk: markdownPaths()", budget: 250) { _ = try vault.markdownPaths() }

// Launch: the graph reads and parses every note.
let graph = NoteGraphIndex(vault: vault)
try measure("graph: reindex (launch)", budget: 3000) { try graph.reindex() }
let busiest = graph.notes.max { graph.backlinks(to: $0.path).count < graph.backlinks(to: $1.path).count }!.path
measure("graph: backlinks of busiest note", budget: 5) { _ = graph.backlinks(to: busiest) }
measure("graph: notes tagged #work", budget: 20) { _ = graph.notes(tagged: "work") }
let edited = notes[notes.count / 2]
measure("graph: apply one saved note", budget: 16) { graph.apply([VaultChange(kind: .modified, path: edited)]) }

// Cmd+O and Shift+Cmd+F run once per keystroke: the first call fills the cache.
let search = VaultSearchService(vault: vault)
// As in the app, which tells it when the vault changes.
search.followChanges()
try measure("search: names \"proj\"", budget: 50) { _ = try search.search("proj", kind: .names, limit: 50) }
try measure("search: content \"réunion client\"", budget: 100) {
    _ = try search.search("réunion client", kind: .content, limit: 50)
}
try measure("search: content, no hit", budget: 100) { _ = try search.search("zzqxw", kind: .content, limit: 50) }

// Tasks panel and Home: every open task of the vault.
let tasks = TaskIndex(vault: vault)
try measure("tasks: all open tasks", budget: 300) { _ = try tasks.tasks(TaskFilter(done: false), liveText: nil) }

if checkBudgets && !failures.isEmpty {
    print("\nOver budget: \(failures.joined(separator: ", "))")
    exit(1)
}
