import XCTest
@testable import JackCore

final class ProgressParserTests: XCTestCase {
    private let mib = 1024.0 * 1024

    func testCurlMeterReportsSizeSpeedAndTimeLeft() throws {
        let reading = try XCTUnwrap(ProgressParser.parse("  45  100M   45 45.2M    0     0  10.1M      0  0:00:09  0:00:04  0:00:05 10.3M"))
        XCTAssertEqual(reading.fraction ?? 0, 0.45, accuracy: 0.0001)
        XCTAssertEqual(reading.total ?? 0, 100 * mib, accuracy: 1)
        XCTAssertEqual(reading.completed ?? 0, 45.2 * mib, accuracy: 1)
        XCTAssertEqual(reading.speed ?? 0, 10.3 * mib, accuracy: 1)
        XCTAssertEqual(reading.eta, 5)
        XCTAssertEqual(reading.unit, "bytes")
    }

    func testCurlWithUnknownSizeHasNoFraction() throws {
        let reading = try XCTUnwrap(ProgressParser.parse("  0     0    0 12.0M    0     0  3.0M      0 --:--:--  0:00:04 --:--:-- 3.1M"))
        XCTAssertNil(reading.fraction)
        XCTAssertNil(reading.eta)
        XCTAssertEqual(reading.completed ?? 0, 12 * mib, accuracy: 1)
    }

    func testAria2Summary() throws {
        let reading = try XCTUnwrap(ProgressParser.parse("[#2089b0 1.2MiB/10MiB(12%) CN:1 DL:3.1MiB ETA:3s]"))
        XCTAssertEqual(reading.fraction ?? 0, 0.12, accuracy: 0.0001)
        XCTAssertEqual(reading.completed ?? 0, 1.2 * mib, accuracy: 1)
        XCTAssertEqual(reading.total ?? 0, 10 * mib, accuracy: 1)
        XCTAssertEqual(reading.speed ?? 0, 3.1 * mib, accuracy: 1)
        XCTAssertEqual(reading.eta, 3)
    }

    func testGitCloneNamesThePhase() throws {
        let reading = try XCTUnwrap(ProgressParser.parse("Receiving objects:  45% (450/1000), 1.20 MiB | 2.30 MiB/s"))
        XCTAssertEqual(reading.fraction ?? 0, 0.45, accuracy: 0.0001)
        XCTAssertEqual(reading.phase, "Receiving objects 450/1000")
        XCTAssertEqual(reading.completed ?? 0, 1.2 * mib, accuracy: 1)
        XCTAssertEqual(reading.speed ?? 0, 2.3 * mib, accuracy: 1)
        XCTAssertEqual(ProgressParser.parse("remote: Counting objects: 100% (5/5), done.")?.phase, "Counting objects 5/5")
    }

    func testTqdmBarFromHuggingFace() throws {
        let reading = try XCTUnwrap(ProgressParser.parse("model.safetensors:  45%|████▌     | 2.10G/4.70G [00:30<00:40, 70.0MB/s]"))
        XCTAssertEqual(reading.fraction ?? 0, 0.45, accuracy: 0.0001)
        XCTAssertEqual(reading.total ?? 0, 4.7 * 1024 * mib, accuracy: 1)
        XCTAssertEqual(reading.speed ?? 0, 70e6, accuracy: 1)
        XCTAssertEqual(reading.eta, 40)
        XCTAssertEqual(reading.phase, "model.safetensors")
    }

    func testOllamaPull() throws {
        let reading = try XCTUnwrap(ProgressParser.parse("pulling 8eeb52dfb3bb:  45% ▕████████        ▏ 2.1 GB/4.7 GB   45 MB/s   1m2s"))
        XCTAssertEqual(reading.completed ?? 0, 2.1e9, accuracy: 1)
        XCTAssertEqual(reading.total ?? 0, 4.7e9, accuracy: 1)
        XCTAssertEqual(reading.speed ?? 0, 45e6, accuracy: 1)
        XCTAssertEqual(reading.eta, 62)
        XCTAssertEqual(reading.phase, "pulling 8eeb52dfb3bb")
    }

    func testWgetPipAndRsync() throws {
        let wget = try XCTUnwrap(ProgressParser.parse("llama.gguf          45%[=======>          ]   2,11G  10,5MB/s    eta 3m 20s"))
        XCTAssertEqual(wget.fraction ?? 0, 0.45, accuracy: 0.0001)
        XCTAssertEqual(wget.speed ?? 0, 10.5e6, accuracy: 1)
        XCTAssertEqual(wget.eta, 200)
        XCTAssertEqual(wget.phase, "llama.gguf")

        let pip = try XCTUnwrap(ProgressParser.parse("   ━━━━━━━━━━━━━━━━━━━━ 2.1/4.7 MB 1.2 MB/s eta 0:00:03"))
        XCTAssertEqual(pip.completed ?? 0, 2.1e6, accuracy: 1)
        XCTAssertEqual(pip.total ?? 0, 4.7e6, accuracy: 1)
        XCTAssertEqual(pip.eta, 3)

        let rsync = try XCTUnwrap(ProgressParser.parse("    1,234,567  45%   10.50MB/s    0:00:05 (xfr#1, to-chk=0/1)"))
        XCTAssertEqual(rsync.fraction ?? 0, 0.45, accuracy: 0.0001)
        XCTAssertEqual(rsync.speed ?? 0, 10.5e6, accuracy: 1)
        XCTAssertEqual(rsync.eta, 5)
    }

    func testOrdinaryLinesAreNotProgress() {
        XCTAssertNil(ProgressParser.parse("Cloning into 'repo'..."))
        XCTAssertNil(ProgressParser.parse("Saved to /tmp/a 2/3"))
        XCTAssertNil(ProgressParser.parse(""))
        XCTAssertEqual(ProgressParser.parse("\u{1B}[32m 100%\u{1B}[0m")?.fraction, 1)
    }

    func testValues() {
        XCTAssertEqual(ProgressParser.bytes("45.2M") ?? 0, 45.2 * mib, accuracy: 1)
        XCTAssertEqual(ProgressParser.bytes("1.5 GB"), 1.5e9)
        XCTAssertEqual(ProgressParser.bytes("512"), 512)
        XCTAssertEqual(ProgressParser.bytes("10k"), 10240)
        XCTAssertNil(ProgressParser.bytes("fast"))
        XCTAssertEqual(ProgressParser.duration("0:00:05"), 5)
        XCTAssertEqual(ProgressParser.duration("01:30"), 90)
        XCTAssertEqual(ProgressParser.duration("1m2s"), 62)
        XCTAssertEqual(ProgressParser.duration("1h 2m"), 3720)
        XCTAssertEqual(ProgressParser.duration("2.5s"), 2.5)
        XCTAssertNil(ProgressParser.duration("--:--:--"))
        XCTAssertEqual(ProgressParser.number("1,5"), 1.5)
        XCTAssertEqual(ProgressParser.number("1,234,567"), 1_234_567)
    }
}

final class ProgressTaskTests: XCTestCase {
    func testTaskFilesAreReadLeniently() {
        let id = UUID()
        let task = ProgressTask(json: ["title": "Cargar modelo", "percent": 40, "completed": "12", "total": 30, "unit": "capas",
                                       "fields": ["Capa": "12"], "kind": "model", "pid": 4321],
                                taskID: "modelo", conversationID: id, modified: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(task.id, id.uuidString + "/modelo")
        XCTAssertEqual(task.status, .running)
        XCTAssertEqual(task.fraction ?? 0, 0.4, accuracy: 0.0001)
        XCTAssertEqual(task.completed, 12)
        XCTAssertEqual(task.fields, [ProgressField(name: "Capa", value: "12")])
        XCTAssertEqual(task.pid, 4321)
        XCTAssertFalse(task.controllable)
        XCTAssertEqual(task.startedAt, Date(timeIntervalSince1970: 100), "missing dates fall back to the file's")
        XCTAssertEqual(ProgressFormat.summary(task), "12 capas de 30 capas")

        let odd = ProgressTask(json: ["fraction": true, "status": "weird"], taskID: "x", conversationID: id, modified: Date())
        XCTAssertNil(odd.fraction, "a boolean is not a fraction")
        XCTAssertEqual(odd.status, .running)
        XCTAssertEqual(odd.title, "x")
        XCTAssertNil(odd.progress)
    }

    func testProgressComesFromAmountsWhenThereIsNoFraction() {
        var task = ProgressTask(taskID: "a", conversationID: UUID(), title: "A")
        XCTAssertNil(task.progress)
        task.completed = 25; task.total = 100
        XCTAssertEqual(task.progress, 0.25)
        task.fraction = 1.4
        XCTAssertEqual(task.progress, 1)
    }

    func testIDsAreSafeFileNames() {
        XCTAssertEqual(ProgressFiles.sanitizedID("Descargando Llama 3 (8B)"), "descargando-llama-3-8b")
        XCTAssertEqual(ProgressFiles.sanitizedID("../../etc/passwd"), "etc-passwd")
        XCTAssertEqual(ProgressFiles.sanitizedID("ñ"), "task")
    }

    func testDurations() {
        XCTAssertEqual(ProgressFormat.duration(45), "45 s")
        XCTAssertEqual(ProgressFormat.duration(192), "3 min 12 s")
        XCTAssertEqual(ProgressFormat.duration(900), "15 min")
        XCTAssertEqual(ProgressFormat.duration(3900), "1 h 5 min")
    }

    func testEveryAgentLearnsAboutProgressAndOnlyOrchestratorsAboutDelegation() {
        let progress = ProgressFiles.isAvailable ? ProgressFiles.helperInstructions : nil
        XCTAssertEqual(ChatRunConfiguration.agentInstructions(delegating: false), progress)
        XCTAssertEqual(ChatRunConfiguration.agentInstructions(delegating: true),
                       [progress, ChatDelegation.instructions].compactMap { $0 }.joined(separator: "\n\n"))
        let claude = ChatRunConfiguration.claudeDelegation(ChatDelegation(url: URL(string: "http://127.0.0.1:1/mcp")!, token: "t"))
        XCTAssertFalse(claude.contains("--append-system-prompt"), "the session adds the instructions once")
    }

    func testEnvironmentPointsAtTheConversationsFolder() {
        let id = UUID()
        let environment = ProgressFiles.environment(for: id)
        XCTAssertEqual(environment[ProgressFiles.directoryKey], ProgressFiles.directory(for: id).path)
        try? FileManager.default.removeItem(at: ProgressFiles.directory(for: id))
    }
}

@MainActor
final class ProgressMonitorTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("jack-progress-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ json: [String: Any], id: String, conversation: UUID, modified: Date) throws {
        let file = root.appendingPathComponent(conversation.uuidString).appendingPathComponent(id + ".json")
        try ProgressFiles.write(json, to: file)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
    }

    func testMonitorListsTasksMeasuresSpeedAndForgetsFinishedOnes() throws {
        let chat = UUID(), other = UUID()
        let start = Date(timeIntervalSince1970: 1_000_000)
        try write(["title": "Modelo", "completed": 0, "total": 3000, "unit": "bytes", "updated_at": start.timeIntervalSince1970],
                  id: "modelo", conversation: chat, modified: start)
        // Finished files older than a week are pruned, so this one is recent.
        try write(["title": "Listo", "status": "done", "finished_at": Date().timeIntervalSince1970], id: "listo", conversation: other, modified: Date())
        let monitor = ProgressMonitor(root: root, watching: false)
        XCTAssertEqual(monitor.tasks.map(\.taskID), ["modelo", "listo"], "active tasks come first")
        XCTAssertEqual(monitor.tasks(for: chat).count, 1)
        XCTAssertNil(monitor.tasks.first?.speed)

        let later = start.addingTimeInterval(2)
        try write(["title": "Modelo", "completed": 1000, "total": 3000, "unit": "bytes", "updated_at": later.timeIntervalSince1970],
                  id: "modelo", conversation: chat, modified: later)
        monitor.scan(now: later)
        let measured = try XCTUnwrap(monitor.tasks.first { $0.taskID == "modelo" })
        XCTAssertEqual(measured.speed ?? 0, 500, accuracy: 0.001)
        XCTAssertEqual(measured.eta ?? 0, 4, accuracy: 0.001)
        XCTAssertEqual(monitor.overallProgress ?? 0, 1.0 / 3, accuracy: 0.001)

        let finished = try XCTUnwrap(monitor.tasks.first { $0.taskID == "listo" })
        XCTAssertEqual(monitor.chatTasks(for: other).map(\.taskID), ["listo"])
        monitor.hideInChat(finished)
        XCTAssertTrue(monitor.chatTasks(for: other).isEmpty)
        XCTAssertEqual(monitor.tasks(for: other).count, 1, "the Downloads panel still lists it")
        monitor.removeFinished()
        XCTAssertEqual(monitor.tasks.map(\.taskID), ["modelo"])
    }

    func testTaskWhoseProcessIsGoneIsInterrupted() throws {
        let chat = UUID()
        try write(["title": "Huérfana", "pid": 99_999_999], id: "huerfana", conversation: chat, modified: Date())
        let monitor = ProgressMonitor(root: root, watching: false)
        XCTAssertEqual(monitor.tasks.first?.status, .interrupted)
        monitor.scan()
        XCTAssertEqual(monitor.tasks.first?.status, .interrupted, "the change is written back to the file")
    }

    func testCancellingATaskWithoutAProcessMarksIt() throws {
        let chat = UUID()
        try write(["title": "Manual"], id: "manual", conversation: chat, modified: Date())
        let monitor = ProgressMonitor(root: root, watching: false)
        let task = try XCTUnwrap(monitor.tasks.first)
        XCTAssertFalse(monitor.canPause(task))
        monitor.cancel(task)
        monitor.scan()
        XCTAssertEqual(monitor.tasks.first?.status, .cancelled)
    }
}

final class ServerScannerTests: XCTestCase {
    func testCommandsReadLikeWhatTheUserTyped() {
        XCTAssertEqual(ServerScanner.commandText(["/usr/local/bin/node", "/work/app/node_modules/.bin/vite", "--port", "5173"], fallback: "node"), "vite --port 5173")
        XCTAssertEqual(ServerScanner.commandText(["npm", "run", "dev"], fallback: "npm"), "npm run dev")
        XCTAssertEqual(ServerScanner.commandText([], fallback: "rails"), "rails")
    }

    func testServersBelongToTheDeepestProject() {
        let projects = ["/work", "/work/app", "/other"]
        XCTAssertEqual(ServerScanner.project(of: "/work/app/web", in: projects), "/work/app")
        XCTAssertEqual(ServerScanner.project(of: "/work", in: projects), "/work")
        XCTAssertNil(ServerScanner.project(of: "/workshop", in: projects), "a folder that only shares a prefix is another project")
        XCTAssertNil(ServerScanner.project(of: "/", in: projects))
    }

    func testImagesGoIntoTheProjectWithoutOverwriting() throws {
        let project = FileManager.default.temporaryDirectory.appendingPathComponent("jack-images-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: project) }
        let first = ChatImageRequest.destination(for: nil, prompt: "Una bicicleta roja", project: project)
        XCTAssertEqual(first.path, project + "/generated-images/una-bicicleta-roja.png")
        try FileManager.default.createDirectory(at: first.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: first.path, contents: Data())
        XCTAssertEqual(ChatImageRequest.destination(for: nil, prompt: "Una bicicleta roja", project: project).lastPathComponent, "una-bicicleta-roja-2.png")
        XCTAssertEqual(ChatImageRequest.destination(for: "public/hero.jpg", prompt: "x", project: project).path, project + "/public/hero.jpg")
        XCTAssertEqual(ChatImageRequest.destination(for: "public/img", prompt: "Cielo", project: project).path, project + "/public/img/cielo.png")

        var request = ChatImageRequest(conversationID: UUID(), prompt: "a red bicycle", destination: first)
        XCTAssertEqual(request.playgroundPrompt, "Photorealistic photo of a red bicycle")
        request.prompt = "foto de una playa"
        XCTAssertEqual(request.playgroundPrompt, "foto de una playa")
        request.style = .sketch; request.prompt = "a cat"
        XCTAssertEqual(request.playgroundPrompt, "a cat")
    }
}
