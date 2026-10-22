import Foundation

struct LocalBuildVariant: Codable, Equatable, Identifiable {
    struct Flavor: Codable, Equatable { let dimension: String; let name: String }
    let name: String
    let applicationId: String
    let buildType: String
    let flavors: [Flavor]
    var id: String { name }
    var flavorLabel: String { flavors.isEmpty ? "无 Flavor" : flavors.map { $0.name }.joined(separator: " / ") }
    var flavorKey: String { flavors.map { $0.dimension + "=" + $0.name }.joined(separator: "|") }
    static let taskName = "logcatMiniDiscoverApplicationVariants"
    static let marker = "LOGCAT_MINI_VARIANT_V1:"

    // Ask AGP after it resolves the project's DSL and plugins. This includes dynamically registered
    // flavors, dimension combinations, suffixes and disabled variants without parsing build.gradle.
    static let initScript = #"""
    import groovy.json.JsonOutput
    gradle.beforeProject { p ->
        p.pluginManager.withPlugin('com.android.application') {
            def variants = []
            def components = p.extensions.findByName('androidComponents')
            if (components == null) throw new GradleException('Android Components API is unavailable')
            components.onVariants(components.selector().all()) { v -> variants.add(v) }
            p.tasks.register('logcatMiniDiscoverApplicationVariants') {
                doLast {
                    variants.each { v ->
                        def entry = [name: v.name, applicationId: v.applicationId.get(), buildType: v.buildType,
                            flavors: v.productFlavors.collect { f -> [dimension: f.first, name: f.second] }]
                        println('LOGCAT_MINI_VARIANT_V1:' + JsonOutput.toJson(entry))
                    }
                }
            }
        }
    }
    """#

    static func parse(_ output: String) throws -> [Self] {
        var entries: [Self] = []
        for line in output.split(whereSeparator: \.isNewline) where line.hasPrefix(marker) {
            let entry = try JSONDecoder().decode(Self.self, from: Data(line.dropFirst(marker.count).utf8))
            guard entry.name.range(of: #"^[a-zA-Z][a-zA-Z0-9_]*$"#, options: .regularExpression) != nil,
                  entry.applicationId.range(of: #"^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$"#, options: .regularExpression) != nil,
                  !entries.contains(where: { $0.name == entry.name }) else { throw LocalBuildError.message("Gradle 返回了无效或重复的构建变体。") }
            entries.append(entry)
        }
        guard !entries.isEmpty else { throw LocalBuildError.message("未读取到 Android 应用变体。请检查模块名和 Gradle 输出；也可以手动填写变体与包名。") }
        return entries.sorted {
            if $0.flavorKey != $1.flavorKey { return $0.flavorKey < $1.flavorKey }
            if ($0.buildType == "debug") != ($1.buildType == "debug") { return $0.buildType == "debug" }
            return $0.name < $1.name
        }
    }
}
