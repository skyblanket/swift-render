import Foundation
import PackagePlugin

/// Compiles Shaders/*.metal into default.metallib at build time, replacing
/// the checked-in metallib + tools/build_shaders.sh manual step.
@main
struct MetalCompilerPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        guard let target = target as? SourceModuleTarget else { return [] }
        let shaderDir = target.directory.appending("Shaders")
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: shaderDir.string) else { return [] }
        let metalFiles = entries.filter { $0.hasSuffix(".metal") }.sorted()
            .map { shaderDir.appending($0) }
        guard !metalFiles.isEmpty else { return [] }

        let out = context.pluginWorkDirectory.appending("default.metallib")
        return [.buildCommand(
            displayName: "Compiling \(metalFiles.count) Metal shaders → default.metallib",
            executable: Path("/usr/bin/xcrun"),
            arguments: ["-sdk", "macosx", "metal"] + metalFiles.map(\.string)
                + ["-o", out.string],
            inputFiles: metalFiles,
            outputFiles: [out]
        )]
    }
}
