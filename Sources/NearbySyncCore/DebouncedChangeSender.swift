import Foundation

public actor DebouncedChangeSender {
    private let delay: Duration
    private var task: Task<Void, Never>?
    private let send: @Sendable () async -> Void

    public init(delay: Duration = .milliseconds(650), send: @escaping @Sendable () async -> Void) {
        self.delay = delay
        self.send = send
    }

    deinit {
        task?.cancel()
    }

    public func schedule() {
        task?.cancel()
        task = Task { [delay, send] in
            do {
                try await Task.sleep(for: delay)
                await send()
            } catch {}
        }
    }

    public func flushNow() {
        task?.cancel()
        task = Task { [send] in
            await send()
        }
    }
}
