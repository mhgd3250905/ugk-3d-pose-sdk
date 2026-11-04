import AVFoundation
import Flutter
import QuartzCore

/// All AVPlayer/registry/event work runs on the platform thread. Only
/// copyPixelBuffer runs on Flutter's raster thread; its shared state is locked.
final class PackedAlphaPlayer: NSObject, FlutterTexture {
  private let textures: FlutterTextureRegistry
  private let publish: (String, [String: Any]) -> Void
  private let player = AVPlayer()
  private let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    kCVPixelBufferMetalCompatibilityKey as String: true,
    kCVPixelBufferIOSurfacePropertiesKey as String: [String: Int](),
  ])
  private var item: AVPlayerItem?
  private var statusObserver: NSKeyValueObservation?
  private var playbackObserver: NSKeyValueObservation?
  private var endObserver: NSObjectProtocol?
  private var failureObserver: NSObjectProtocol?
  private var metadataTask: Task<Void, Never>?
  private var displayLink: CADisplayLink?
  private var ready = false
  private var wantsPlay = false
  private var active = true
  private var visible = true
  private var looping = false
  private let frameLock = NSLock()
  private var disposed = false
  private var latestFrame: CVPixelBuffer?
  private var firstFrame = false
  private(set) var textureID: Int64 = 0

  init(textures: FlutterTextureRegistry, publish: @escaping (String, [String: Any]) -> Void) {
    self.textures = textures
    self.publish = publish
    super.init()
    player.isMuted = true
    player.preventsDisplaySleepDuringVideoPlayback = false
    textureID = textures.register(self)
  }

  func prepare(url: URL) {
    let item = AVPlayerItem(url: url)
    self.item = item
    item.add(output)
    statusObserver = item.observe(\.status, options: [.initial, .new]) { [weak self] _, _ in
      self?.onMain { $0.statusChanged() }
    }
    playbackObserver = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
      self?.onMain { owner in
        if owner.ready { owner.emitState() }
      }
    }
    endObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
    ) { [weak self] _ in self?.loop() }
    failureObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
    ) { [weak self] note in
      self?.fail(note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError)
    }
    player.replaceCurrentItem(with: item)
  }

  private func onMain(_ work: @escaping (PackedAlphaPlayer) -> Void) {
    if Thread.isMainThread {
      if !disposed { work(self) }
    } else {
      DispatchQueue.main.async { [weak self] in
        guard let self = self, !self.disposed else { return }
        work(self)
      }
    }
  }

  private func statusChanged() {
    guard !disposed, let item = item else { return }
    switch item.status {
    case .readyToPlay:
      guard metadataTask == nil, !ready else { return }
      metadataTask = Task { @MainActor [weak self] in
        do {
          let tracks = try await item.asset.loadTracks(withMediaType: .video)
          guard let track = tracks.first else {
            self?.failDimensions()
            return
          }
          let size = try await track.load(.naturalSize)
          let transform = try await track.load(.preferredTransform)
          let bounds = CGRect(origin: .zero, size: size).applying(transform)
          let width = abs(bounds.width).rounded()
          let height = abs(bounds.height).rounded()
          guard let self = self, !self.disposed, !Task.isCancelled,
            item.status == .readyToPlay else { return }
          guard width.isFinite, height.isFinite, width > 0, height == width * 2 else {
            self.failDimensions()
            return
          }
          // Video output buffers do not apply track orientation automatically.
          // Normalize rotated sources so metadata and Flutter texture agree.
          if !transform.isIdentity {
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
            layer.setTransform(transform.concatenating(
              CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY)), at: .zero)
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: .zero, duration: item.duration)
            instruction.layerInstructions = [layer]
            let composition = AVMutableVideoComposition()
            composition.instructions = [instruction]
            composition.renderSize = CGSize(width: width, height: height)
            composition.frameDuration = CMTime(value: 1, timescale: 30)
            item.videoComposition = composition
          }
          self.ready = true
          let duration = item.duration.seconds
          self.emit("ready", ["width": Int(width), "height": Int(height),
                              "duration": duration.isFinite ? duration : 0.0])
          self.syncPlayback()
        } catch {
          guard !Task.isCancelled else { return }
          self?.fail(error as NSError)
        }
      }
    case .failed: fail(item.error as NSError?)
    default: break
    }
  }

  private func failDimensions() {
    guard !disposed else { return }
    stopPlayback()
    emit("error", ["code": "invalid_packed_dimensions"])
  }

  private func fail(_ error: NSError?) {
    guard !disposed else { return }
    stopPlayback()
    if let error = error {
      emit("error", ["domain": error.domain, "code": error.code])
    } else {
      emit("error", ["code": "player_failed"])
    }
  }

  private func stopPlayback() {
    ready = false
    wantsPlay = false
    player.pause()
    displayLink?.invalidate()
    displayLink = nil
  }

  func play() { wantsPlay = true; syncPlayback() }
  func pause() { wantsPlay = false; syncPlayback() }
  func setActive(_ value: Bool) {
    active = value
    if !value { wantsPlay = false }
    syncPlayback()
  }
  func setVisible(_ value: Bool) { visible = value; syncPlayback() }
  func position() -> Double? {
    guard ready, !disposed else { return nil }
    let seconds = player.currentTime().seconds
    return seconds.isFinite ? seconds : nil
  }

  private func syncPlayback() {
    guard ready, !disposed else { return }
    if wantsPlay && active && visible && !looping {
      player.play()
      if displayLink == nil {
        let link = CADisplayLink(target: DisplayLinkTarget(self), selector: #selector(DisplayLinkTarget.tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
      }
    } else {
      player.pause()
      displayLink?.invalidate()
      displayLink = nil
    }
    emitState()
  }

  private func emitState() { emit("state", ["playing": player.timeControlStatus == .playing]) }

  private func loop() {
    guard ready, !disposed else { return }
    looping = true
    // Keep latestFrame and the one-time first-frame flag across the seek.
    // Flutter keeps displaying the last frame, never an empty texture/poster.
    syncPlayback()
    player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
      self?.onMain { owner in
        owner.looping = false
        if finished { owner.syncPlayback() }
      }
    }
  }

  fileprivate func pullFrame(_ link: CADisplayLink) {
    guard ready, !disposed, wantsPlay, active, visible else { return }
    let time = output.itemTime(forHostTime: link.targetTimestamp)
    guard output.hasNewPixelBuffer(forItemTime: time),
      let frame = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else { return }
    frameLock.lock()
    latestFrame = frame
    frameLock.unlock()
    textures.textureFrameAvailable(textureID)
  }

  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    frameLock.lock()
    guard !disposed, let frame = latestFrame else {
      frameLock.unlock()
      return nil
    }
    let announce = !firstFrame
    firstFrame = true
    let retained = Unmanaged.passRetained(frame)
    frameLock.unlock()
    if announce {
      DispatchQueue.main.async { [weak self] in self?.emit("first-frame") }
    }
    return retained
  }

  private func emit(_ type: String, _ fields: [String: Any] = [:]) {
    if !disposed { publish(type, fields) }
  }

  func dispose() {
    guard !disposed else { return }
    frameLock.lock()
    disposed = true
    latestFrame = nil
    frameLock.unlock()
    metadataTask?.cancel()
    metadataTask = nil
    statusObserver?.invalidate()
    statusObserver = nil
    playbackObserver?.invalidate()
    playbackObserver = nil
    if let observer = endObserver { NotificationCenter.default.removeObserver(observer) }
    if let observer = failureObserver { NotificationCenter.default.removeObserver(observer) }
    endObserver = nil
    failureObserver = nil
    stopPlayback()
    item?.remove(output)
    player.replaceCurrentItem(with: nil)
    item = nil
    textures.unregisterTexture(textureID)
  }
}

private final class DisplayLinkTarget: NSObject {
  weak var owner: PackedAlphaPlayer?
  init(_ owner: PackedAlphaPlayer) { self.owner = owner }
  @objc func tick(_ link: CADisplayLink) { owner?.pullFrame(link) }
}
