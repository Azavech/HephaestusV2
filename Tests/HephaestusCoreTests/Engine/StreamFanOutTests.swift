import Foundation
import Testing
@testable import HephaestusCore

/// The event and state streams of the connections (`StreamFanOut`).
@Suite("Stream fan-out")
struct StreamFanOutTests {
    @Test("Consumers cancelled while elements are delivered neither deadlock nor stop the others")
    func cancelDuringDelivery() async throws {
        let fanOut = StreamFanOut<Int>()
        let kept = fanOut.stream()
        let count = 20_000
        let delivered = Task {
            var received = 0
            for await _ in kept {
                received += 1
                if received == count { break }
            }
            return received
        }
        let producerDone = DispatchSemaphore(value: 0)
        let stopCancelling = Recorder<Bool>()
        // Consumers suspended in `next()` are cancelled from other threads while the producer
        // yields: each cancellation runs the stream's termination handler, which removes the
        // consumer from the fan-out. One consumer at a time: the next one is made once the
        // cancelled one ended, so that the work stays the same however late the tasks start.
        let canceller = Thread {
            while stopCancelling.values.isEmpty {
                let stream = fanOut.stream()
                let started = DispatchSemaphore(value: 0)
                let ended = DispatchSemaphore(value: 0)
                let task = Task.detached {
                    started.signal()
                    for await _ in stream {}
                    ended.signal()
                }
                started.wait()
                usleep(50)
                task.cancel()
                ended.wait()
            }
        }
        canceller.start()
        DispatchQueue.global(qos: .userInitiated).async {
            for element in 0..<count {
                fanOut.yield(element)
            }
            producerDone.signal()
        }
        // The producer only yields, which never waits: the bound only ends a deadlocked run.
        let finished = await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                continuation.resume(returning: producerDone.wait(timeout: .now() + 120) == .success)
            }
        }
        stopCancelling.append(true)
        #expect(finished, "the producer is blocked: the fan-out deadlocked")
        guard finished else { return }
        #expect(await delivered.value == count)
        fanOut.finish()
    }

    @Test("A stream made after finish ends at once, after its initial element")
    func finishedStream() async {
        let fanOut = StreamFanOut<Int>()
        fanOut.finish()
        var elements: [Int] = []
        for await element in fanOut.stream(initial: 7) {
            elements.append(element)
        }
        #expect(elements == [7])
    }
}
