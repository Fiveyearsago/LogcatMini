import Foundation

struct LocalBuildProject: Codable, Equatable, Identifiable {
    var packageID = ""
    var directory = ""
    var module = "app"
    var variant = "debug"
    var javaHome = ""
    var sdkRoot = ""
    var lowMemory = true
    // Optional so previously saved 0.16.0 associations still decode without migration.
    var variantCatalog: [LocalBuildVariant]?
    var variantCatalogScope: String?
    var id: String { packageID }
    var root: URL { URL(fileURLWithPath: directory).standardizedFileURL }
    var task: String { ":" + module + ":assemble" + variant.prefix(1).uppercased() + variant.dropFirst() }

    var catalogScope: String { root.resolvingSymlinksInPath().path + "\n" + module }
    var availableVariants: [LocalBuildVariant] { variantCatalogScope == catalogScope ? (variantCatalog ?? []) : [] }
    var selectedVariant: LocalBuildVariant? { availableVariants.first { $0.name == variant } }

    func validate(packageRequired: Bool = true) throws {
        guard !packageRequired || packageID.range(of: #"^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$"#, options: .regularExpression) != nil else {
            throw LocalBuildError.message("请填写有效的 App 包名。")
        }
        guard module.range(of: #"^[A-Za-z0-9_-]+(:[A-Za-z0-9_-]+)*$"#, options: .regularExpression) != nil,
              variant.range(of: #"^[a-zA-Z][a-zA-Z0-9_]*$"#, options: .regularExpression) != nil else {
            throw LocalBuildError.message("模块和构建变体格式无效，例如 app / debug 或 app / demoDebug。")
        }
        guard directory.hasPrefix("/"), FileManager.default.isReadableFile(atPath: root.appendingPathComponent("gradlew").path) else {
            throw LocalBuildError.message("请选择包含 gradlew 的 Android 项目根目录。")
        }
        guard FileManager.default.isExecutableFile(atPath: javaHome + "/bin/java") else {
            throw LocalBuildError.message("JDK 路径无效，请选择包含 bin/java 的 JDK Home。")
        }
        guard FileManager.default.isExecutableFile(atPath: sdkRoot + "/platform-tools/adb") else {
            throw LocalBuildError.message("Android SDK 路径无效，请选择包含 platform-tools 的目录。")
        }
    }

    static func properties(at url: URL) -> [String: String] {
        guard let text = try? String(contentsOf: url) else { return [:] }
        var result: [String: String] = [:]
        for raw in text.replacingOccurrences(of: "\\\n", with: "").split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), !line.hasPrefix("!"), let separator = line.firstIndex(of: "=") else { continue }
            result[String(line[..<separator]).trimmingCharacters(in: .whitespaces)] = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
        }
        return result
    }

    var buildArguments: [String] {
        arguments(for: task)
    }
    func arguments(for task: String) -> [String] {
        var arguments = [root.appendingPathComponent("gradlew").path, task, "--console=plain", "--no-daemon"]
        if lowMemory {
            let userHome = ProcessInfo.processInfo.environment["GRADLE_USER_HOME"] ?? NSHomeDirectory() + "/.gradle"
            let local = Self.properties(at: root.appendingPathComponent("gradle.properties"))
            let user = Self.properties(at: URL(fileURLWithPath: userHome + "/gradle.properties"))
            let original = user["org.gradle.jvmargs"] ?? local["org.gradle.jvmargs"] ?? "-Dfile.encoding=UTF-8"
            let retained = original.replacingOccurrences(of: #"(?<!\S)-Xmx\S+"#, with: "", options: .regularExpression)
            arguments += ["--max-workers=2", "--no-parallel", "-Dorg.gradle.jvmargs=\(retained) -Xmx3g", "-Pkotlin.compiler.execution.strategy=in-process"]
        }
        // A project/user Gradle property must not silently choose a different JDK.
        arguments.append("-Dorg.gradle.java.home=" + javaHome)
        return arguments
    }

    func artifact() throws -> URL {
        struct Metadata: Decodable {
            struct Element: Decodable { let outputFile: String; let filters: [Filter] }
            struct Filter: Decodable {}
            let applicationId: String
            let variantName: String
            let elements: [Element]
        }
        let outputs = root.appendingPathComponent(module.replacingOccurrences(of: ":", with: "/") + "/build/outputs/apk").resolvingSymlinksInPath()
        let files = FileManager.default.enumerator(at: outputs, includingPropertiesForKeys: [.isRegularFileKey])
        var matches: [URL] = []
        while let file = files?.nextObject() as? URL {
            guard file.lastPathComponent == "output-metadata.json",
                  let data = try? Data(contentsOf: file), let metadata = try? JSONDecoder().decode(Metadata.self, from: data),
                  metadata.variantName.caseInsensitiveCompare(variant) == .orderedSame else { continue }
            guard metadata.applicationId == packageID else { throw LocalBuildError.message("产物包名为 \(metadata.applicationId)，与关联的 \(packageID) 不一致，已停止安装。") }
            guard metadata.elements.count == 1, let element = metadata.elements.first, element.filters.isEmpty else {
                throw LocalBuildError.message("此变体生成了拆分 APK。首版请使用生成单个通用 APK 的变体。")
            }
            let apk = file.deletingLastPathComponent().appendingPathComponent(element.outputFile).resolvingSymlinksInPath()
            guard apk.path.hasPrefix(outputs.path + "/"), apk.pathExtension.lowercased() == "apk",
                  let values = try? apk.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true, (values.fileSize ?? 0) > 0 else {
                throw LocalBuildError.message("构建产物缺失或路径无效，请检查 Gradle 输出。")
            }
            matches.append(apk)
        }
        guard matches.count == 1, let apk = matches.first else { throw LocalBuildError.message("未找到唯一的 \(variant) APK，请检查模块、变体和 output-metadata.json。") }
        return apk
    }

    func aapt() throws -> String {
        let folder = URL(fileURLWithPath: sdkRoot).appendingPathComponent("build-tools")
        let versions = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for version in versions.sorted(by: { $0.compare($1, options: .numeric) == .orderedDescending }) {
            let path = folder.appendingPathComponent(version + "/aapt2").path
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        throw LocalBuildError.message("Android SDK 缺少 build-tools/aapt2，无法核对 APK 包名。")
    }
}

enum LocalBuildError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
