import XCTest

final class MicGainTests: XCTestCase {
    func testGainIsBoundedAndPreservesWaveform() {
        let cases: [(peak: Float, expected: Float)] = [
            (0, 0), (0.002, 0.002), (0.02, 0.16), (0.2, 0.7), (0.9, 0.9),
        ]
        for (peak, expected) in cases {
            var samples = [peak, -peak, peak * 0.5]
            AudioRecorder.liftQuietMic(&samples, frames: 3)
            XCTAssertEqual(samples[0], expected, accuracy: 0.00001)
            XCTAssertEqual(samples[1], -expected, accuracy: 0.00001)
            XCTAssertEqual(samples[2], expected * 0.5, accuracy: 0.00001)
        }
    }
}
