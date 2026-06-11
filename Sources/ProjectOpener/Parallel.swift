import Foundation

enum Parallel {
    /// Runs `body` for indices 0..<count on a bounded worker pool. Unlike
    /// `concurrentPerform`, the limit can exceed the core count, which helps
    /// when the work is dominated by waiting on child processes.
    static func each(_ count: Int, limit: Int, _ body: @escaping (Int) -> Void) {
        guard count > 0 else { return }
        let workers = min(limit, count)
        guard workers > 1 else {
            for i in 0..<count { body(i) }
            return
        }
        let lock = NSLock()
        var cursor = 0
        let group = DispatchGroup()
        let queue = DispatchQueue.global(qos: .userInitiated)
        for _ in 0..<workers {
            queue.async(group: group) {
                while true {
                    lock.lock()
                    let i = cursor
                    cursor += 1
                    lock.unlock()
                    guard i < count else { return }
                    body(i)
                }
            }
        }
        group.wait()
    }
}
