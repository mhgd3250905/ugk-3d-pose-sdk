import AVFoundation
import Flutter
import XCTest

// Compile alongside Sources/ugk_trainer_runtime in a Flutter iOS host's
// RunnerTests target. No production assets, network or signing are required.
final class PackedAlphaTests: XCTestCase {
  private var temporary: [URL] = []

  override func tearDownWithError() throws {
    for url in temporary { try FileManager.default.removeItem(at: url) }
    temporary.removeAll()
  }

  private func movie(width: Int = 32, height: Int = 64) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
    temporary.append(url)
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
      AVVideoCodecKey: AVVideoCodecType.h264,
      AVVideoWidthKey: width, AVVideoHeightKey: height,
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
      sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    writer.add(input)
    XCTAssertTrue(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    var buffer: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, width, height,
      kCVPixelFormatType_32BGRA, nil, &buffer), kCVReturnSuccess)
    let frame = try XCTUnwrap(buffer)
    CVPixelBufferLockBaseAddress(frame, [])
    let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(frame)).assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRow(frame)
    for y in 0..<height {
      for x in 0..<width {
        let pixel = base + y * stride + x * 4
        // Upper half: red. Lower half: alpha 0 (left) and 1 (right).
        let alpha: UInt8 = x < width / 2 ? 0 : 255
        pixel[0] = y < height / 2 ? 0 : alpha
        pixel[1] = y < height / 2 ? 0 : alpha
        pixel[2] = y < height / 2 ? 255 : alpha
        pixel[3] = 255
      }
    }
    CVPixelBufferUnlockBaseAddress(frame, [])
    let done = expectation(description: "H264 fixture")
    let encoding = DispatchQueue(label: "ugk.packed-alpha.fixture")
    // Let AVFoundation signal capacity on a serial queue. Polling on the test
    // thread can starve encoding; never append after a readiness timeout.
    var index = 0
    input.requestMediaDataWhenReady(on: encoding) {
      guard index < 30 else { return }
      while input.isReadyForMoreMediaData && index < 30 {
        let appended = adaptor.append(frame,
          withPresentationTime: CMTime(value: Int64(index), timescale: 30))
        XCTAssertTrue(appended)
        guard appended else {
          index = 30
          writer.cancelWriting()
          done.fulfill()
          return
        }
        index += 1
      }
      if index == 30 {
        input.markAsFinished()
        writer.finishWriting { done.fulfill() }
      }
    }
    wait(for: [done], timeout: 30)
    XCTAssertEqual(writer.status, .completed)
    return url
  }

  func testSourceBoundaryAndExclusiveCreateArguments() throws {
    let file = try movie()
    XCTAssertEqual(try PackedAlphaSource.validate(file.absoluteString), file)
    for uri in ["http://localhost/demo.mp4", "https://example.test/demo.MP4"] {
      XCTAssertNoThrow(try PackedAlphaSource.validate(uri))
    }
    for uri in [
      "relative.mp4", "file:relative.mp4", "content://media/demo.mp4", "ftp://host/demo.mp4",
      "file://server/demo.mp4", "file:///missing-demo.mp4", "https:/demo.mp4",
      "https://user:secret@host/demo.mp4", "https://host/demo.mp4?", "https://host/demo.mp4#",
      "https://host/a/../demo.mp4", "https://host/a/%2e%2e/demo.mp4", "https://host/./demo.mp4",
      "https://host/demo.webp",
    ] { XCTAssertThrowsError(try PackedAlphaSource.validate(uri), uri) }
    let asset: (String) -> URL? = { $0 == "assets/demo.mp4" ? file : nil }
    XCTAssertEqual(try PackedAlphaSource.resolve(["asset": "assets/demo.mp4"], assetURL: asset), file)
    XCTAssertEqual(try PackedAlphaSource.resolve(["sourceUri": file.absoluteString], assetURL: asset), file)
    for args: [String: Any] in [[:], ["asset": "missing.mp4"], ["asset": 4],
      ["asset": "assets/demo.mp4", "sourceUri": file.absoluteString],
      ["asset": 4, "sourceUri": file.absoluteString]] {
      XCTAssertThrowsError(try PackedAlphaSource.resolve(args, assetURL: asset))
    }
  }

  func testInvalidDimensionsNeverBecomeReady() throws {
    let registry = TestTextures()
    let failed = expectation(description: "invalid dimensions")
    var received: [String] = []
    let player = PackedAlphaPlayer(textures: registry) { type, fields in
      received.append(type)
      if type == "error" {
        XCTAssertEqual(fields["code"] as? String, "invalid_packed_dimensions")
        failed.fulfill()
      }
    }
    player.prepare(url: try movie(height: 32))
    player.play()
    wait(for: [failed], timeout: 10)
    XCTAssertFalse(received.contains("ready"))
    XCTAssertNil(player.position())
    player.dispose()
    XCTAssertEqual(registry.unregistered, [player.textureID])
  }

  func testDecodeControlsLoopAndDisposeKeepOneFirstFrame() throws {
    let registry = TestTextures()
    let ready = expectation(description: "ready metadata")
    let frame = expectation(description: "actual Flutter frame handoff")
    var events: [String] = []
    var playingStates: [Bool] = []
    let player = PackedAlphaPlayer(textures: registry) { type, fields in
      events.append(type)
      if type == "ready" {
        XCTAssertEqual(fields["width"] as? Int, 32)
        XCTAssertEqual(fields["height"] as? Int, 64)
        XCTAssertEqual(fields["duration"] as? Double ?? 0, 1, accuracy: 0.1)
        ready.fulfill()
      }
      if type == "first-frame" { frame.fulfill() }
      if type == "state", let playing = fields["playing"] as? Bool { playingStates.append(playing) }
      XCTAssertNotEqual(type, "error")
    }
    defer { player.dispose() }
    XCTAssertNil(player.position())
    player.prepare(url: try movie())
    wait(for: [ready], timeout: 10)
    XCTAssertFalse(events.contains("first-frame"))
    player.play()
    wait(for: [frame], timeout: 10)
    XCTAssertTrue(playingStates.contains(true))
    let buffer = try XCTUnwrap(registry.frame)
    XCTAssertEqual(CVPixelBufferGetPixelFormatType(buffer), kCVPixelFormatType_32BGRA)
    XCTAssertEqual(CVPixelBufferGetWidth(buffer), 32)
    XCTAssertEqual(CVPixelBufferGetHeight(buffer), 64)
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    // H.264 color conversion is lossy; test plane/channel order separately
    // from the grayscale alpha endpoints below.
    XCTAssertGreaterThan(base[8 * stride + 8 * 4 + 2], 200) // RGB red
    XCTAssertLessThan(base[8 * stride + 8 * 4], 30)
    XCTAssertLessThan(base[8 * stride + 8 * 4 + 1], 30)
    XCTAssertLessThan(base[48 * stride + 8 * 4 + 2], 8) // alpha reaches 0
    XCTAssertGreaterThan(base[48 * stride + 24 * 4 + 2], 247) // alpha reaches 1
    CVPixelBufferUnlockBaseAddress(buffer, .readOnly)

    player.pause()
    let paused = try XCTUnwrap(player.position())
    settle(0.15)
    XCTAssertEqual(player.position() ?? -1, paused, accuracy: 0.04)
    player.setVisible(false)
    player.play()
    settle(0.1)
    XCTAssertEqual(player.position() ?? -1, paused, accuracy: 0.04)
    player.setVisible(true)
    settle(0.2)
    XCTAssertGreaterThan(player.position() ?? -1, paused + 0.05)
    player.setActive(false)
    let inactive = try XCTUnwrap(player.position())
    player.setActive(true) // active=false cleared wantsPlay
    settle(0.15)
    XCTAssertEqual(player.position() ?? -1, inactive, accuracy: 0.04)
    player.play()
    var wrapped = false
    var previous = try XCTUnwrap(player.position())
    for _ in 0..<25 {
      settle(0.1)
      let now = try XCTUnwrap(player.position())
      if now < previous - 0.2 { wrapped = true; break }
      previous = now
    }
    XCTAssertTrue(wrapped, "currentTime must wrap without a training clock")
    XCTAssertEqual(events.filter { $0 == "first-frame" }.count, 1)
    XCTAssertEqual(registry.emptyFrames, 0)
    player.dispose()
    let count = events.count
    settle(0.2)
    XCTAssertEqual(events.count, count)
    XCTAssertNil(player.copyPixelBuffer())
    XCTAssertNil(player.position())
    player.dispose()
    XCTAssertEqual(registry.unregistered.count, 1)
  }

  func testEarlyDisposeCancelsReadyAndUnregistersOnce() throws {
    let registry = TestTextures()
    var events: [String] = []
    let player = PackedAlphaPlayer(textures: registry) { type, _ in events.append(type) }
    player.prepare(url: try movie())
    player.play()
    player.dispose()
    player.dispose()
    settle(0.3)
    XCTAssertTrue(events.isEmpty)
    XCTAssertEqual(registry.unregistered.count, 1)
  }

  private func settle(_ seconds: TimeInterval) {
    let settled = expectation(description: "platform run loop")
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { settled.fulfill() }
    wait(for: [settled], timeout: seconds + 2)
  }
}

private final class TestTextures: NSObject, FlutterTextureRegistry {
  private var texture: FlutterTexture?
  var frame: CVPixelBuffer?
  var emptyFrames = 0
  var unregistered: [Int64] = []
  func register(_ texture: FlutterTexture) -> Int64 { self.texture = texture; return 101 }
  func textureFrameAvailable(_ textureId: Int64) {
    // Mimic the raster thread consuming a retained CoreVideo buffer.
    let next = DispatchQueue.global().sync { texture?.copyPixelBuffer()?.takeRetainedValue() }
    if let next = next { frame = next } else { emptyFrames += 1 }
  }
  func unregisterTexture(_ textureId: Int64) { unregistered.append(textureId); texture = nil }
}
