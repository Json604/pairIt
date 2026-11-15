import Foundation
import Network

/// Bounded display-only query. It never authenticates a receiver or starts capture.
final class ComputerOccupancy {
    struct Status { let count: Int; var names = "" }
    static func check(pin: String, host: String) async -> Status {
        await withCheckedContinuation { continuation in
            let probe = ComputerOccupancy()
            probe.start(pin: pin, host: host) { continuation.resume(returning: $0) }
        }
    }
    private let queue = DispatchQueue(label: "pairit.occupancy")
    private var connection: NWConnection?
    private var timer: DispatchSourceTimer?
    private var reply = Data()
    private var completion: ((Status) -> Void)?
    private func start(pin: String, host: String, completion: @escaping (Status) -> Void) {
        queue.async { [self] in
            self.completion = completion
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 4)
            timer.setEventHandler { [self] in finish(Status(count: -1)) }; self.timer = timer; timer.resume()
            let current = NWConnection(host: .init(host), port: 5002, using: RelaySecurity.parameters(pin: pin, queue: queue))
            connection = current
            current.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready: current.send(content: Data("STATUS1\n".utf8), completion: .contentProcessed { [weak self] error in
                    if error == nil { self?.receive() } else { self?.finish(Status(count: -1)) }
                })
                case .failed, .cancelled: self.finish(Status(count: -1))
                default: break
                }
            }
            current.start(queue: queue)
        }
    }
    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 1536) { [weak self] data, _, ended, error in
            guard let self else { return }
            if let data { self.reply.append(data) }
            guard self.reply.count <= 1536 else { self.finish(Status(count: -1)); return }
            if self.reply.contains(10) {
                let value = String(data: self.reply, encoding: .ascii) ?? ""
                let parts = value.trimmingCharacters(in: .newlines).split(separator: " ", maxSplits: 3, omittingEmptySubsequences: false)
                guard parts.count >= 3, parts[0] == "OK", parts[1] == "STATUS1", let count = Int(parts[2]), (0...4).contains(count) else { self.finish(Status(count: -1)); return }
                var status = Status(count: count)
                if parts.count == 4, let data = Data(base64Encoded: String(parts[3])), let name = String(data: data, encoding: .utf8), name.count <= 262,
                   !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || $0.properties.generalCategory == .format }) { status.names = name }
                self.finish(status); return
            }
            if ended || error != nil { self.finish(Status(count: -1)) } else { self.receive() }
        }
    }
    private func finish(_ count: Status) {
        guard let completed = completion else { return }; completion = nil
        timer?.setEventHandler {}; timer?.cancel(); timer = nil
        connection?.stateUpdateHandler = nil; connection?.cancel(); connection = nil
        completed(count)
    }
}
