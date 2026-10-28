import Foundation
import Darwin
import os

/// Runs a helper process under hard limits: it is killed when it runs past `timeout`, writes more than `outputLimit`
/// bytes, or its memory footprint passes `memoryLimit`, and when the calling task is cancelled. Standard input gets
/// `input`; standard error is discarded; no other file of this process is inherited.
///
/// Used for work on content the app does not control, such as the router's own scripts (RouterMenuEvaluator): a
/// script that loops or allocates without end costs a process that can be stopped, not a thread of the app.
///
/// The child is reaped here, on one serial queue that also sends every kill: until it is reaped its process id stays
/// its own (a zombie keeps it), so a kill can never reach another process that later got the same id.
public enum BoundedProcess {
    public enum Failure: Error, Equatable, Sendable {
        case launch(String)
        case timeout
        case outputTooLarge
        case memory
        case cancelled
        case exit(Int32)
        case signal(Int32)
    }
    public struct Limits: Sendable {
        public var timeout: TimeInterval
        public var outputLimit: Int
        public var memoryLimit: UInt64
        public init(timeout: TimeInterval, outputLimit: Int, memoryLimit: UInt64) {
            self.timeout = timeout; self.outputLimit = outputLimit; self.memoryLimit = memoryLimit
        }
    }

    /// Standard output of a process that exited with status 0.
    public static func run(executable: URL, arguments: [String], input: Data, limits: Limits) async throws -> Data {
        let job = Job(executable: executable, arguments: arguments, input: input, limits: limits)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in job.start(continuation) }
        } onCancel: { job.stop(.cancelled) }
    }

    /// Physical footprint, as Activity Monitor's Memory column counts it.
    static func footprint(of pid: pid_t) -> UInt64? {
        var info = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
        }
        return result == 0 ? info.ri_phys_footprint : nil
    }

    private final class Job: @unchecked Sendable {
        private struct State {
            var continuation: CheckedContinuation<Data, Error>?
            var stopReason: Failure?
            var output = Data()
            var outputDone = false
            /// The child is gone but its output is still held open (by a process it started): stop waiting for it.
            var abandonOutput = false
            /// waitpid's status once the child has been reaped.
            var exitStatus: Int32?
            var finished = false
        }
        private let executable: URL
        private let arguments: [String]
        private let input: Data
        private let limits: Limits
        private let state = OSAllocatedUnfairLock(initialState: State())
        /// Reaps, measures and kills: everything that uses the process id runs here.
        private let queue = DispatchQueue(label: "BoundedProcess", qos: .utility)
        // Touched on `queue` only.
        private var pid: pid_t = 0
        private var reaped = false
        private var watchdog: DispatchSourceTimer?

        init(executable: URL, arguments: [String], input: Data, limits: Limits) {
            self.executable = executable; self.arguments = arguments; self.input = input; self.limits = limits
        }

        func start(_ continuation: CheckedContinuation<Data, Error>) {
            let stopped = state.withLock { state -> Failure? in
                state.continuation = continuation
                return state.stopReason
            }
            if let stopped { return finish(.failure(stopped)) }
            var toChild: [Int32] = [-1, -1], fromChild: [Int32] = [-1, -1]
            guard pipe(&toChild) == 0 else { return finish(.failure(.launch("pipe"))) }
            guard pipe(&fromChild) == 0 else { close(toChild[0]); close(toChild[1]); return finish(.failure(.launch("pipe"))) }
            // A child that exits before reading its input must not take this process down with SIGPIPE. Both ends this
            // process keeps are non-blocking and waited on with poll(), so a run that gives up on the child (or on a process
            // it started that holds a pipe) stops waiting.
            guard fcntl(toChild[1], F_SETNOSIGPIPE, 1) == 0, Self.setNonBlocking(toChild[1]), Self.setNonBlocking(fromChild[0]) else {
                for end in toChild + fromChild { close(end) }
                return finish(.failure(.launch("fcntl")))
            }
            var child: pid_t = 0
            let spawned = spawn(&child, stdin: toChild[0], stdout: fromChild[1])
            close(toChild[0]); close(fromChild[1])
            guard spawned == 0 else {
                close(toChild[1]); close(fromChild[0])
                return finish(.failure(.launch(String(cString: strerror(spawned)))))
            }

            let input = input, writeEnd = toChild[1], readEnd = fromChild[0], spawnedPID = child
            DispatchQueue.global(qos: .utility).async { [self] in
                input.withUnsafeBytes { buffer in
                    var offset = 0
                    var ready = pollfd(fd: writeEnd, events: Int16(POLLOUT), revents: 0)
                    // Until everything is written, the child stops reading for good (EPIPE), or the run has ended or stopped.
                    while offset < buffer.count, !state.withLock({ $0.finished || $0.stopReason != nil || $0.abandonOutput }) {
                        let polled = poll(&ready, 1, 100)
                        if polled < 0, errno != EINTR { break }
                        guard polled > 0 else { continue }
                        let written = write(writeEnd, buffer.baseAddress! + offset, buffer.count - offset)
                        if written > 0 { offset += written } else if written < 0, errno == EINTR || errno == EAGAIN { continue } else { break }
                    }
                }
                close(writeEnd)
            }
            DispatchQueue.global(qos: .utility).async { [self] in
                var buffer = [UInt8](repeating: 0, count: 65_536)
                var ready = pollfd(fd: readEnd, events: Int16(POLLIN), revents: 0)
                reading: while !state.withLock({ $0.abandonOutput }) {
                    let polled = poll(&ready, 1, 100)
                    if polled < 0, errno != EINTR { break }
                    guard polled > 0 else { continue }
                    // Output that keeps coming does not keep a run that gave up on it waiting.
                    while !state.withLock({ $0.abandonOutput }) {
                        let count = read(readEnd, &buffer, buffer.count)
                        if count < 0, errno == EINTR { continue }
                        if count < 0, errno == EAGAIN { break }
                        // 0: every writer has closed it; below 0: it cannot be read.
                        guard count > 0 else { break reading }
                        let chunk = Data(buffer[0..<count])
                        let over = state.withLock { state -> Bool in
                            guard state.stopReason == nil else { return false }
                            state.output.append(chunk)
                            return state.output.count > limits.outputLimit
                        }
                        if over { stop(.outputTooLarge) }
                    }
                }
                close(readEnd)
                complete { $0.outputDone = true }
            }
            let started = DispatchTime.now()
            queue.async { [self] in
                pid = spawnedPID
                // Stopped while it was starting: the stop's kill found no process id yet.
                if state.withLock({ $0.stopReason != nil }) { Darwin.kill(spawnedPID, SIGKILL) }
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now() + .milliseconds(25), repeating: .milliseconds(25))
                timer.setEventHandler { [self] in tick(started: started) }
                watchdog = timer
                timer.resume()
            }
        }

        private static func setNonBlocking(_ descriptor: Int32) -> Bool {
            let flags = fcntl(descriptor, F_GETFL)
            return flags >= 0 && fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0
        }

        /// posix_spawn with standard input and output on the pipes and standard error on /dev/null, and no other file of
        /// this process. Every preparation step is checked, so the child never starts with a cut argument list (which
        /// would start the app instead of the helper). Returns 0 or the error number.
        private func spawn(_ child: inout pid_t, stdin: Int32, stdout: Int32) -> Int32 {
            var actions: posix_spawn_file_actions_t?
            var attributes: posix_spawnattr_t?
            guard posix_spawn_file_actions_init(&actions) == 0 else { return ENOMEM }
            defer { posix_spawn_file_actions_destroy(&actions) }
            guard posix_spawnattr_init(&attributes) == 0 else { return ENOMEM }
            defer { posix_spawnattr_destroy(&attributes) }
            let argv = ([executable.path] + arguments).map { strdup($0) }
            let envp = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") }
            defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
            guard !argv.contains(nil), !envp.contains(nil) else { return ENOMEM }
            var step = posix_spawn_file_actions_adddup2(&actions, stdin, 0)
            if step == 0 { step = posix_spawn_file_actions_adddup2(&actions, stdout, 1) }
            if step == 0 { step = posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0) }
            if step == 0 { step = posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)) }
            guard step == 0 else { return step }
            return posix_spawn(&child, executable.path, &actions, &attributes, argv + [nil], envp + [nil])
        }

        /// On `queue`: reaps the child once it has exited, enforcing the time and memory limits until then; afterwards,
        /// its output still held open by a process it started is waited for only until the time limit or a stop.
        private func tick(started: DispatchTime) {
            guard pid > 0 else { return }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1e9
            if !reaped {
                var status: Int32 = 0
                let result = waitpid(pid, &status, WNOHANG)
                guard result == pid || (result == -1 && errno == ECHILD) else {
                    guard state.withLock({ $0.stopReason == nil }) else { return }
                    if elapsed > limits.timeout { stop(.timeout); return }
                    if let used = BoundedProcess.footprint(of: pid), used > limits.memoryLimit { stop(.memory) }
                    return
                }
                reaped = true
                let exitStatus = result == pid ? status : 0
                complete { $0.exitStatus = exitStatus }
            }
            let (done, stopped) = state.withLock { ($0.outputDone || $0.finished, $0.stopReason != nil) }
            if done { watchdog?.cancel(); watchdog = nil; return }
            if stopped || elapsed > limits.timeout {
                state.withLock { state in
                    if state.stopReason == nil { state.stopReason = .timeout }
                    state.abandonOutput = true
                }
            }
        }

        func stop(_ reason: Failure) {
            let stopping = state.withLock { state -> Bool in
                guard !state.finished, state.stopReason == nil else { return false }
                state.stopReason = reason
                return true
            }
            guard stopping else { return }
            // The kill goes through `queue`, so it either precedes the reap or finds the child already reaped.
            queue.async { [self] in if pid > 0, !reaped { Darwin.kill(pid, SIGKILL) } }
        }

        /// Records one of the two ends (output closed, child reaped); the second one finishes the run.
        private func complete(_ part: @Sendable (inout State) -> Void) {
            let outcome = state.withLock { state -> Swift.Result<Data, Failure>? in
                part(&state)
                guard !state.finished, state.outputDone, let status = state.exitStatus else { return nil }
                if let reason = state.stopReason { return .failure(reason) }
                if status & 0x7f == 0 {
                    let code = (status >> 8) & 0xff
                    return code == 0 ? .success(state.output) : .failure(.exit(code))
                }
                return .failure(.signal(status & 0x7f))
            }
            if let outcome { finish(outcome) }
        }

        private func finish(_ result: Swift.Result<Data, Failure>) {
            let continuation = state.withLock { state -> CheckedContinuation<Data, Error>? in
                guard !state.finished else { return nil }
                state.finished = true
                defer { state.continuation = nil }
                return state.continuation
            }
            continuation?.resume(with: result.mapError { $0 as Error })
        }
    }
}
