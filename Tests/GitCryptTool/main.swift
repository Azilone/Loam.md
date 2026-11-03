import Foundation
import GitSyncPlugin

// `loam crypt …` for the git sync's tests: the same code as the command line's, without building CLI/.
exit(GitCrypt.main(Array(CommandLine.arguments.dropFirst())))
