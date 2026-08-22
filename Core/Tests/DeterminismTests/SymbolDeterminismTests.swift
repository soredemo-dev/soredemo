import Testing
import Foundation

// MARK: - why this is a test and not a plugin rule
//
// Rule 3 is checked over LINK-TIME SYMBOLS, not source text: every syntactic evasion
// of `Date()` collapses into one mangled symbol. A build-tool plugin cannot read
// object files, so this lives in a test whose deps order the compilation ahead of it.

/// …/Tests/DeterminismTests/SymbolDeterminismTests.swift → the repository root.
let repositoryRoot = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// A floor, so a filter that quietly matches nothing cannot look like a pass; the
/// authoritative list comes from the resolved manifest (`scannedModules()`).
let libraryModules = ["Geometry", "Timeline", "Graph", "Framing", "Variants", "Project", "Render"]

// MARK: - the banned symbols
//
// Derived, not guessed: each name was read off `nm -u` of a scratch module on this
// toolchain, a derivation `bannedConstructFixture` reproduces. Absent on purpose:
// `Date`/`UUID` as TYPES, the INSTANCE `timeIntervalSinceReferenceDate` (the static
// one mangles with a trailing `Z`, so matching is exact), and `random(in:using:)`.
let bannedSymbols: [String: String] = [
    // ── ambient time ────────────────────────────────────────────────────────────
    "_$s10Foundation4DateVACycfC":                              "Date.init()",
    "_$s10Foundation4DateV3nowACvgZ":                           "static Date.now",
    "_$s10Foundation4DateV20timeIntervalSinceNowACSd_tcfC":     "Date.init(timeIntervalSinceNow:)",
    "_$s10Foundation4DateV20timeIntervalSinceNowSdvg":          "Date.timeIntervalSinceNow",
    "_$s10Foundation4DateV026timeIntervalSinceReferenceB0SdvgZ": "static Date.timeIntervalSinceReferenceDate",
    "_$s8Dispatch0A4TimeV3nowACyFZ":                            "DispatchTime.now()",
    "_$s8Dispatch0A8WallTimeV3nowACyFZ":                        "DispatchWallTime.now()",
    "_$ss15ContinuousClockVABycfC":                             "ContinuousClock.init()",
    "_$ss15ContinuousClockV3nowAB7InstantVvg":                  "ContinuousClock.now",
    "_$ss15ContinuousClockV3nowAB7InstantVvgZ":                 "static ContinuousClock.now",
    "_$ss15SuspendingClockVABycfC":                             "SuspendingClock.init()",
    "_$ss15SuspendingClockV3nowAB7InstantVvg":                  "SuspendingClock.now",
    "_$ss15SuspendingClockV3nowAB7InstantVvgZ":                 "static SuspendingClock.now",
    "_CFAbsoluteTimeGetCurrent":                                "CFAbsoluteTimeGetCurrent()",
    "_mach_absolute_time":                                      "mach_absolute_time()",
    "_mach_approximate_time":                                   "mach_approximate_time()",
    // Advances during sleep where `mach_absolute_time` does not: a different reading.
    "_mach_continuous_time":                                    "mach_continuous_time()",
    "_clock_gettime_nsec_np":                                   "clock_gettime_nsec_np()",
    "_clock_gettime":                                           "clock_gettime()",
    // Processor time for this process: ambient, and exact-matched, not by substring.
    "_clock":                                                   "clock()",
    "_gettimeofday":                                            "gettimeofday()",
    "_time":                                                    "time()",
    // ObjC clock reads. `NSDate` is over-approximated: ANY reference trips this.
    "_OBJC_CLASS_$_NSDate":                                     "NSDate (any reference)",
    "_objc_msgSend$timeIntervalSinceReferenceDate":             "-[NSDate timeIntervalSinceReferenceDate]",
    "_objc_msgSend$systemUptime":                               "-[NSProcessInfo systemUptime]",

    // ── ambient randomness ──────────────────────────────────────────────────────
    "_$s10Foundation4UUIDVACycfC":                              "UUID.init()",
    // Over-approximated exactly as `NSDate` is: ANY reference trips it.
    "_OBJC_CLASS_$_NSUUID":                                     "NSUUID (any reference)",
    "_$ss17FixedWidthIntegerPsE6random2inxSnyxG_tFZ":           "FixedWidthInteger.random(in: Range)",
    "_$ss17FixedWidthIntegerPsE6random2inxSNyxG_tFZ":           "FixedWidthInteger.random(in: ClosedRange)",
    "_$sSBss17FixedWidthInteger14RawSignificandRpzrlE6random2inxSnyxG_tFZ":
        "BinaryFloatingPoint.random(in: Range)",
    "_$sSBss17FixedWidthInteger14RawSignificandRpzrlE6random2inxSNyxG_tFZ":
        "BinaryFloatingPoint.random(in: ClosedRange)",
    "_$sSb6randomSbyFZ":                                        "Bool.random()",
    "_$sSlsE13randomElement0B0QzSgyF":                          "Collection.randomElement()",
    "_$sSTsE8shuffledSay7ElementQzGyF":                         "Sequence.shuffled()",
    "_$sSMsSkRzrlE7shuffleyyF":                                 "MutableCollection.shuffle()",
    "_$ss27SystemRandomNumberGeneratorVABycfC":                 "SystemRandomNumberGenerator.init()",
    "_$ss27SystemRandomNumberGeneratorV4nexts6UInt64VyF":       "SystemRandomNumberGenerator.next()",
    "_arc4random":                                              "arc4random()",
    "_arc4random_uniform":                                      "arc4random_uniform()",
    "_arc4random_buf":                                          "arc4random_buf()",
    "_arc4random_stir":                                         "arc4random_stir()",

    // ── the `drand48` family, and the process-global state it mutates ───────────
    //
    // Unseeded `drand48` is deterministic, but its state is PROCESS-GLOBAL: the
    // reader stays deterministic exactly until `srand48`/`seed48`/`lcong48` runs, so
    // the writers are banned too. `erand48` takes its state in an argument, and the
    // rest of the family is unavailable to Swift, so neither needs a ban.
    "_drand48":                                                 "drand48()",
    "_srand48":                                                 "srand48()",
    "_seed48":                                                  "seed48()",
    "_lcong48":                                                 "lcong48()",
    // `Security`'s CSPRNG, reachable with plain `import Foundation`, so rule 1's
    // import scan never sees it arrive. `kSecRandomDefault` is listed separately
    // because it is its own symbol and the fixture keeps one call site per entry.
    "_SecRandomCopyBytes":                                      "SecRandomCopyBytes()",
    "_kSecRandomDefault":                                       "kSecRandomDefault (any reference)",
]

/// One call site per entry in `bannedSymbols` — read back by
/// `everyBannedSymbolIsStillWhatTheConstructEmits`, so a renamed mangling goes red.
let bannedConstructFixture = """
import Foundation

public func t01() -> Date { Date() }
public func t02() -> Date { Date.now }
public func t03() -> Date { Date(timeIntervalSinceNow: 1) }
public func t04(_ d: Date) -> Double { d.timeIntervalSinceNow }
public func t05() -> Double { Date.timeIntervalSinceReferenceDate }
public func t06() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
public func t07() -> DispatchWallTime { DispatchWallTime.now() }
public func t08() -> ContinuousClock { ContinuousClock() }
public func t09() -> ContinuousClock.Instant { ContinuousClock.now }
public func t10(_ c: ContinuousClock) -> ContinuousClock.Instant { c.now }
public func t11() -> SuspendingClock { SuspendingClock() }
public func t12() -> SuspendingClock.Instant { SuspendingClock.now }
public func t13(_ c: SuspendingClock) -> SuspendingClock.Instant { c.now }
public func t14() -> Double { CFAbsoluteTimeGetCurrent() }
public func t15() -> UInt64 { mach_absolute_time() }
public func t16() -> UInt64 { mach_approximate_time() }
public func t17() -> UInt64 { clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) }
public func t18() -> Int32 { var ts = timespec(); return clock_gettime(CLOCK_MONOTONIC, &ts) }
public func t19() -> Int32 { var tv = timeval(); return gettimeofday(&tv, nil) }
public func t20() -> time_t { time(nil) }
public func t21() -> NSDate { NSDate() }
public func t22() -> Double { NSDate.timeIntervalSinceReferenceDate }
public func t23() -> Double { ProcessInfo.processInfo.systemUptime }

public func t24() -> UUID { UUID() }
public func t25() -> Int { Int.random(in: 0..<10) }
public func t26() -> Int { Int.random(in: 0...10) }
public func t27() -> Double { Double.random(in: 0..<1) }
public func t28() -> Double { Double.random(in: 0...1) }
public func t29() -> Bool { Bool.random() }
public func t30(_ a: [Int]) -> Int? { a.randomElement() }
public func t31(_ a: [Int]) -> [Int] { a.shuffled() }
public func t32(_ a: inout [Int]) { a.shuffle() }
public func t33() -> UInt64 { var g = SystemRandomNumberGenerator(); return g.next() }
public func t34(_ p: UnsafeMutableRawPointer) { arc4random_buf(p, 8) }
public func t35() -> UInt32 { arc4random() }
public func t36() -> UInt32 { arc4random_uniform(10) }
public func t37() -> UInt64 { mach_continuous_time() }
public func t38() -> OSStatus {
    var bytes = [UInt8](repeating: 0, count: 8)
    return SecRandomCopyBytes(kSecRandomDefault, 8, &bytes)
}
public func t39() -> SecRandomRef { kSecRandomDefault }
public func t40() -> NSUUID { NSUUID() }
public func t41() -> clock_t { clock() }
public func t42() -> Double { drand48() }
public func t43() { srand48(1) }
public func t44(_ x: inout [UInt16]) { _ = seed48(&x) }
public func t45(_ x: inout [UInt16]) { lcong48(&x) }
public func t46() { arc4random_stir() }
"""

/// The other side: idiomatic deterministic code — stored `Date`/`UUID`, values parsed
/// from bytes, an injected generator. A false positive here would block real work.
let deterministicFixture = """
import Foundation

/// The shape D-P4 prescribes: the timestamp and the identifier are MINTED IN THE APP
/// and passed in as plain values. Storing them is correct; constructing them is not.
public struct Observation: Sendable, Equatable {
    public let at: Date
    public let id: UUID
    public init(at: Date, id: UUID) { self.at = at; self.id = id }
}

public func epochSeconds(_ o: Observation) -> Double { o.at.timeIntervalSince1970 }
public func referenceSeconds(_ o: Observation) -> Double { o.at.timeIntervalSinceReferenceDate }
public func ordered(_ a: Observation, _ b: Observation) -> Bool { a.at < b.at }
public func fromEpoch(_ t: Double) -> Date { Date(timeIntervalSince1970: t) }
public func fromReference(_ t: Double) -> Date { Date(timeIntervalSinceReferenceDate: t) }
public func parse(_ s: String) -> UUID? { UUID(uuidString: s) }
public func rawBytes(_ o: Observation) -> UInt8 { o.id.uuid.0 }
public func drawn<G: RandomNumberGenerator>(_ g: inout G) -> Int { Int.random(in: 0..<10, using: &g) }
public func drawnElement<G: RandomNumberGenerator>(_ a: [Int], _ g: inout G) -> Int? {
    a.randomElement(using: &g)
}
"""

// MARK: - reading symbols

/// `nm -u` prints one undefined symbol per line and nothing else for a single input.
func undefinedSymbols(in objectFile: URL) throws -> Set<String> {
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/nm")
    process.arguments = ["-u", objectFile.path(percentEncoded: false)]
    let out = Pipe()
    let err = Pipe()
    process.standardOutput = out
    process.standardError = err
    try process.run()
    // Drained before waiting: a Pipe nobody reads blocks the child once it fills.
    let data = out.fileHandleForReading.readDataToEndOfFile()
    let errorText = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    try #require(process.terminationStatus == 0,
                 "nm -u failed on \(objectFile.path(percentEncoded: false)): \(errorText)")
    return Set(String(decoding: data, as: UTF8.self)
        .split(whereSeparator: \.isNewline)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty })
}

/// Every object file carrying `module`'s code. Both SwiftPM layouts are searched: a
/// linked `<Module>.o`, and per-source objects under `<Module>.build/`.
func objectFiles(forModule module: String, in binDirectory: URL) -> [URL] {
    var found: [URL] = []

    let linked = binDirectory.appending(path: "\(module).o")
    if FileManager.default.fileExists(atPath: linked.path(percentEncoded: false)) {
        found.append(linked)
    }

    let perSource = binDirectory.appending(path: "\(module).build")
    let contents = (try? FileManager.default.contentsOfDirectory(
        at: perSource, includingPropertiesForKeys: nil)) ?? []
    found += contents.filter { $0.pathExtension == "o" }

    return found
}

/// The resolved manifest, not its text, so a renamed or added target is picked up.
func dumpPackage() throws -> [String: Any] {
    let scratch = URL(filePath: NSTemporaryDirectory())
        .appending(path: "determinism-dump-\(ProcessInfo.processInfo.globallyUniqueString)")
    defer { try? FileManager.default.removeItem(at: scratch) }

    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/env")
    // A separate --scratch-path keeps this off the `.build` the enclosing test holds.
    process.arguments = ["swift", "package", "dump-package",
                         "--scratch-path", scratch.path(percentEncoded: false)]
    process.currentDirectoryURL = repositoryRoot
    let out = Pipe()
    process.standardOutput = out
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    try #require(process.terminationStatus == 0, "swift package dump-package failed")
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

/// Every regular target the `ArchitectureCheck` plugin is attached to — derived
/// rather than listed, so a seventh library target is covered the day it is added.
func scannedModules(inDump dump: [String: Any]) throws -> [String] {
    let targets = try #require(dump["targets"] as? [[String: Any]])
    let names = targets.filter { target in
        guard target["type"] as? String == "regular" else { return false }
        let usages = target["pluginUsages"] as? [[String: Any]] ?? []
        return usages.contains { ($0["plugin"] as? [Any])?.first as? String == "ArchitectureCheck" }
    }.compactMap { $0["name"] as? String }

    try #require(Set(names).isSuperset(of: libraryModules),
                 "expected at least \(libraryModules) among the plugin-checked targets, got \(names.sorted())")
    return names.sorted()
}

/// The real compiler: reimplementing Swift's mangler here would test the test.
func compileToObject(_ source: String, named name: String) throws -> URL {
    let dir = URL(filePath: NSTemporaryDirectory())
        .appending(path: "determinism-fixture-\(ProcessInfo.processInfo.globallyUniqueString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let swiftFile = dir.appending(path: "\(name).swift")
    let objectFile = dir.appending(path: "\(name).o")
    try source.write(to: swiftFile, atomically: true, encoding: .utf8)

    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/env")
    process.arguments = ["swiftc", "-swift-version", "6", "-emit-object",
                         "-o", objectFile.path(percentEncoded: false),
                         swiftFile.path(percentEncoded: false)]
    let err = Pipe()
    process.standardError = err
    try process.run()
    let errorText = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    try #require(process.terminationStatus == 0, "fixture \(name) did not compile:\n\(errorText)")
    return objectFile
}

/// `symbol → the construct it came from`, for every banned symbol the file references.
func bannedSymbolsReferenced(by objectFile: URL) throws -> [String: String] {
    let undefined = try undefinedSymbols(in: objectFile)
    return bannedSymbols.filter { undefined.contains($0.key) }
}

// MARK: - the rule

/// RULE 3. No package module may reference an ambient clock or the system RNG.
@Test func noLibraryModuleReferencesAmbientTimeOrRandomness() throws {
    let binDirectory = repositoryRoot.appending(path: ".build/debug")
    let modules = try scannedModules(inDump: try dumpPackage())

    var allObjectFiles: [URL] = []
    for module in modules {
        let files = objectFiles(forModule: module, in: binDirectory)
        // Per module, not just in total: the aggregate cannot see one module missing.
        try #require(!files.isEmpty,
                     """
                     no object files found for \(module) under \
                     \(binDirectory.path(percentEncoded: false)) — the symbol check \
                     would pass vacuously for it
                     """)
        allObjectFiles += files
    }

    // Kept beside the per-module guard: a different failure, and it looks like a pass.
    try #require(!allObjectFiles.isEmpty,
                 "no object files found under \(binDirectory.path()) — the symbol check would pass vacuously")

    var undefinedSymbolsFound: Set<String> = []
    var violations: [String] = []
    for objectFile in allObjectFiles {
        let undefined = try undefinedSymbols(in: objectFile)
        undefinedSymbolsFound.formUnion(undefined)
        for symbol in bannedSymbols.keys where undefined.contains(symbol) {
            violations.append("\(objectFile.lastPathComponent): \(bannedSymbols[symbol]!)  [\(symbol)]")
        }
    }

    try #require(!undefinedSymbolsFound.isEmpty,
                 "nm returned no undefined symbols — the check is not reading what it thinks it is")

    #expect(violations.isEmpty,
            """
            ambient time or randomness reached the package (ArchitectureCheck rule 3):
            \(violations.sorted().joined(separator: "\n"))
            IDs and timestamps are minted in the app and passed in as plain values.
            """)
}

// MARK: - the table is not allowed to go stale

/// Every entry is still the symbol its construct emits on THIS toolchain. Without
/// this, a mangling change would empty the rule silently and still read as a pass.
@Test func everyBannedSymbolIsStillWhatTheConstructEmits() throws {
    let objectFile = try compileToObject(bannedConstructFixture, named: "BannedConstructs")
    let undefined = try undefinedSymbols(in: objectFile)
    try #require(!undefined.isEmpty, "nm returned no undefined symbols for the banned-construct fixture")

    let missing = bannedSymbols
        .filter { !undefined.contains($0.key) }
        .map { "\($0.value)  [\($0.key)]" }
        .sorted()
    #expect(missing.isEmpty,
            """
            these banned symbols are no longer emitted by the construct they were \
            derived from — the mangling changed and the rule is now enforcing less \
            than it claims:
            \(missing.joined(separator: "\n"))
            """)
}

/// THE RED: the scan really does reject a module that reads the clock or the system
/// RNG, checked against the compiled fixture rather than asserted.
@Test func theScanRejectsAModuleThatReadsTheClockOrTheSystemRNG() throws {
    let objectFile = try compileToObject(bannedConstructFixture, named: "BannedConstructs")
    let found = try bannedSymbolsReferenced(by: objectFile)
    #expect(found.count == bannedSymbols.count,
            "expected all \(bannedSymbols.count) banned constructs to be caught, caught \(found.count)")
}

// MARK: - the other side: what must NOT be rejected

/// A module that STORES a `Date` and a `UUID` without constructing one must not trip
/// the rule. Also pins the instance `timeIntervalSinceReferenceDate` (allowed; the
/// banned static one differs only by a trailing `Z`) and `random(in:using:)`.
@Test func aModuleThatOnlyStoresDatesAndUUIDsIsAccepted() throws {
    let objectFile = try compileToObject(deterministicFixture, named: "Deterministic")
    let undefined = try undefinedSymbols(in: objectFile)

    // The fixture really does use the types, or it would prove nothing.
    try #require(undefined.contains("_$s10Foundation4DateVMa"),
                 "the fixture does not reference Foundation.Date at all — it proves nothing")
    try #require(undefined.contains("_$s10Foundation4UUIDVMa"),
                 "the fixture does not reference Foundation.UUID at all — it proves nothing")

    let found = try bannedSymbolsReferenced(by: objectFile)
    #expect(found.isEmpty,
            """
            idiomatic deterministic code was rejected — a false positive here blocks \
            real work and teaches people to route around the rule:
            \(found.values.sorted().joined(separator: "\n"))
            """)
}

/// The same distinction in shipped code: `DisplayGeometry.displayUUID` is a stored
/// `UUID`, so `Geometry.o` references the type but never `UUID.init()`.
@Test func geometryReferencesTheUUIDTypeWithoutConstructingOne() throws {
    let files = objectFiles(forModule: "Geometry",
                            in: repositoryRoot.appending(path: ".build/debug"))
    try #require(!files.isEmpty, "no object files found for Geometry — nothing was checked")

    var undefined: Set<String> = []
    for file in files { undefined.formUnion(try undefinedSymbols(in: file)) }

    #expect(undefined.contains("_$s10Foundation4UUIDVMa"),
            "Geometry stores a UUID (DisplayGeometry.displayUUID) and must reference its metadata")
    #expect(!undefined.contains("_$s10Foundation4UUIDVACycfC"),
            "Geometry must not construct a UUID")
}

// MARK: - the vacuous-pass guards

/// An empty search finds no violations and reads as a pass. These two tests pin the
/// CONDITIONS the guards fire on, so the guards are known to be reachable.

@Test func anEmptySearchDirectoryYieldsNoObjectFiles() throws {
    let empty = URL(filePath: NSTemporaryDirectory())
        .appending(path: "determinism-empty-\(ProcessInfo.processInfo.globallyUniqueString)")
    try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: empty) }

    for module in libraryModules {
        #expect(objectFiles(forModule: module, in: empty).isEmpty,
                "an empty directory must yield no object files, or the first guard can never fire")
    }
}

/// The second guard is reachable too: a self-contained object yields no undefined
/// symbols, which the banned-symbol filter reports as clean.
@Test func anObjectFileCanYieldNoUndefinedSymbolsAtAll() throws {
    let dir = URL(filePath: NSTemporaryDirectory())
        .appending(path: "determinism-zero-\(ProcessInfo.processInfo.globallyUniqueString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let source = dir.appending(path: "zero.c")
    let object = dir.appending(path: "zero.o")
    try "int soredemo_probe_zero(void) { return 0; }\n"
        .write(to: source, atomically: true, encoding: .utf8)

    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/env")
    process.arguments = ["clang", "-c", source.path(percentEncoded: false),
                         "-o", object.path(percentEncoded: false)]
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    try #require(process.terminationStatus == 0, "clang failed to build the zero-symbol probe")

    let undefined = try undefinedSymbols(in: object)
    #expect(undefined.isEmpty,
            "a self-contained object file must yield no undefined symbols, or the second guard can never fire")
    #expect(try bannedSymbolsReferenced(by: object).isEmpty,
            "and it reads as clean — which is exactly why the guard is needed")
}

// MARK: - the mechanism must not be voidable

/// Deleting a module from `DeterminismTests`' dependency list voids the ordering
/// guarantee this check rests on, with no build failure and no diagnostic.
@Test func determinismTestTargetDependsOnEveryCheckedModule() throws {
    let dump = try dumpPackage()
    let modules = try scannedModules(inDump: dump)

    let targets = try #require(dump["targets"] as? [[String: Any]])
    let determinismTests = try #require(targets.first { $0["name"] as? String == "DeterminismTests" },
                                        "the DeterminismTests target is gone — rule 3 has no mechanism")

    let dependencies = determinismTests["dependencies"] as? [[String: Any]] ?? []
    let names = Set(dependencies.compactMap { ($0["byName"] as? [Any])?.first as? String })

    #expect(names.isSuperset(of: modules),
            """
            DeterminismTests does not depend on \(Set(modules).subtracting(names).sorted()), \
            so nothing orders their compilation before the symbol check runs. \
            Add them to the target's dependencies in Package.swift.
            """)
}
