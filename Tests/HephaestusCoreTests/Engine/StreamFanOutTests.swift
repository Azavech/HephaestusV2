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
        // consumer from the fan-out.
        let canceller = Thread {
            while stopCancelling.values.isEmpty {
                let stream = fanOut.stream()
                let task = Task.detached {
                    for await _ in stream {}
                }
                usleep(50)
                task.cancel()
            }
        }
        canceller.start()
        DispatchQueue.global(qos: .userInitiated).async {
            for element in 0..<count {
                fanOut.yield(element)
            }
            producerDone.signal()
        }
        let finished = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: producerDone.wait(timeout: .now() + 20) == .success)
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
