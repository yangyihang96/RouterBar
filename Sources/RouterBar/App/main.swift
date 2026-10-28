import AppKit
import RouterCore

// A child of the app evaluating the router's menu scripts (RouterMenuEvaluator): no window, no app.
if CommandLine.arguments.dropFirst().first == RouterMenuEvaluator.childArgument {
    exit(RouterMenuEvaluator.serveChild())
}
#if ROUTERBAR_PREVIEW
// Development builds only: render the main screens with sample data to PNG files and quit (PreviewRenderer).
if let index = CommandLine.arguments.firstIndex(of: "--render-previews"), index + 1 < CommandLine.arguments.count {
    let folder = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
    MainActor.assumeIsolated { PreviewRenderer.run(to: folder) }
    exit(0)
}
#endif
RouterBarApp.main()
