import FrontEnd
import StandardLibrary
import Utils

@main
struct MyApp {

    static func buildProgram() async throws {
      var diagnostics: DiagnosticSet = DiagnosticSet()
      let ast = try Host.hostedLibraryAST.get()
      let _ = try TypedProgram(
        annotating: ScopedProgram(ast), inParallel: false,
        reportingDiagnosticsTo: &diagnostics,
        tracingInferenceIf: nil)
    }

    static func main() async throws {
      print("async main!")
      try await MyApp.buildProgram()
      print("Built standard library")
    }
}

