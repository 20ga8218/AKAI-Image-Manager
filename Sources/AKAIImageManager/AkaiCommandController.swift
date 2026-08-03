@preconcurrency import Foundation

actor AkaiCommandController {
    private var process: Process?
    private var input: FileHandle?
    private var eventStream: AsyncStream<Data>?
    private var iterator: AsyncStream<Data>.Iterator?
    private var continuation: AsyncStream<Data>.Continuation?
    private var bufferedOutput = ""
    private(set) var state: ControllerState = .closed
    private(set) var session: ImageSession?
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func open(imageURL: URL, executableURL: URL, readOnly: Bool) async throws -> CommandResult {
        guard state == .closed || isFailed else { throw AppError.controllerBusy }
        guard fileManager.isExecutableFile(atPath: executableURL.path) else {
            throw AppError.invalidExecutable(executableURL.path)
        }
        guard fileManager.fileExists(atPath: imageURL.path) else {
            throw AppError.processFailed("The image does not exist.")
        }

        state = .launching
        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.executableURL = executableURL
        var arguments: [String] = []
        if readOnly { arguments.append("-r") }
        if Self.isFloppySized(imageURL, fileManager: fileManager) { arguments.append("-f") }
        arguments.append(imageURL.path)
        process.arguments = arguments
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        let pair = AsyncStream<Data>.makeStream()
        eventStream = pair.stream
        continuation = pair.continuation
        iterator = pair.stream.makeAsyncIterator()
        outputPipe.fileHandleForReading.readabilityHandler = { [continuation = pair.continuation] handle in
            let data = handle.availableData
            if data.isEmpty {
                continuation.finish()
            } else {
                continuation.yield(data)
            }
        }
        process.terminationHandler = { [continuation = pair.continuation] _ in
            continuation.finish()
        }

        do {
            try process.run()
        } catch {
            reset()
            state = .failed(error.localizedDescription)
            throw AppError.processFailed(error.localizedDescription)
        }

        self.process = process
        input = inputPipe.fileHandleForWriting
        bufferedOutput = ""

        do {
            let banner = try await readUntilPrompt()
            guard process.isRunning else {
                let detail = OutputCleaner.clean(banner)
                reset()
                state = .failed(detail)
                throw AppError.processFailed(detail.isEmpty ? "The process exited while opening the image." : detail)
            }
            let removable = USBVolumeResolver.owningVolume(for: imageURL)
            session = ImageSession(imageURL: imageURL, readOnly: readOnly, removableVolumeURL: removable, openedAt: Date())
            state = .ready
            return CommandResult(command: "open", output: banner, cleanedOutput: OutputCleaner.clean(banner))
        } catch {
            if process.isRunning { process.terminate() }
            reset()
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    func send(_ command: String) async throws -> CommandResult {
        guard state == .ready else {
            if state == .closed { throw AppError.noImageOpen }
            throw AppError.controllerBusy
        }
        if session?.readOnly == true && Self.isMutating(command) { throw AppError.readOnly }
        let safeCommand = try AkaiCommandBuilder.validate(command)
        guard let input, process?.isRunning == true else {
            state = .failed("AKAI Util is not running.")
            throw AppError.processFailed("AKAI Util is not running.")
        }

        state = .running(safeCommand)
        do {
            try input.write(contentsOf: Data((safeCommand + "\n").utf8))
            let response = try await readUntilPrompt()
            state = .ready
            return CommandResult(command: safeCommand, output: response, cleanedOutput: OutputCleaner.clean(response))
        } catch {
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    func cancel() {
        guard case .running = state else { return }
        process?.interrupt()
    }

    func close() async {
        guard let process else {
            reset()
            state = .closed
            return
        }
        state = .quitting
        if process.isRunning {
            try? input?.write(contentsOf: Data("q\n".utf8))
            await waitForTermination(process)
        }
        reset()
        state = .closed
    }

    private func readUntilPrompt() async throws -> String {
        while true {
            if let range = PromptDetector.terminalPromptRange(in: bufferedOutput) {
                let end = range.upperBound
                let complete = String(bufferedOutput[..<end])
                bufferedOutput = String(bufferedOutput[end...])
                return complete
            }
            guard var currentIterator = iterator else {
                let output = bufferedOutput
                bufferedOutput = ""
                throw AppError.promptNotFound(OutputCleaner.clean(output))
            }
            let nextData = await currentIterator.next()
            iterator = currentIterator
            guard let data = nextData else {
                let output = bufferedOutput
                bufferedOutput = ""
                throw AppError.promptNotFound(OutputCleaner.clean(output))
            }
            bufferedOutput.append(String(decoding: data, as: UTF8.self))
        }
    }

    private func waitForTermination(_ process: Process) async {
        if !process.isRunning { return }
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                process.waitUntilExit()
                continuation.resume()
            }
        }
    }

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    private func reset() {
        input?.closeFile()
        input = nil
        process?.terminationHandler = nil
        process = nil
        continuation?.finish()
        continuation = nil
        iterator = nil
        eventStream = nil
        bufferedOutput = ""
        session = nil
    }

    private static func isFloppySized(_ url: URL, fileManager: FileManager) -> Bool {
        let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value
        return size == 800 * 1024 || size == 1600 * 1024
    }

    private static func isMutating(_ command: String) -> Bool {
        let safe = [
            "df", "dinfo", "pwd", "dir", "ls", "dirrec", "lsrec",
            "infoi", "infoall", "help", "lcd", "cd", "cdi",
            "geti", "sample2wavi"
        ]
        let verb = command.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        return !safe.contains(verb)
    }
}
