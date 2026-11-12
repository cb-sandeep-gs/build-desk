import Foundation

// `BuildDeskApp --snapshot out.png` renders the window to an image and exits; anything else opens the app.
if CommandLine.arguments.contains(Snapshot.Argument.snapshot) {
    exit(await Snapshot.run(arguments: CommandLine.arguments))
}
BuildDeskApp.main()
