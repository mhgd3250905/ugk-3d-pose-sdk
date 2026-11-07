import Flutter
import Foundation

/// iOS registers only packed video. Training keep-alive remains Android-only.
public final class UgkTrainerPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  private let registrar: FlutterPluginRegistrar
  private let methods: FlutterMethodChannel
  private let events: FlutterEventChannel
  private var players: [Int64: PackedAlphaPlayer] = [:]
  private var sink: FlutterEventSink?
  // Preserve event order and at most the last event of each type per player.
  private var pending: [Int64: [(type: String, event: [String: Any])]] = [:]
  private var nextID: Int64 = 1

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = UgkTrainerPlugin(registrar: registrar)
    registrar.addMethodCallDelegate(instance, channel: instance.methods)
    instance.events.setStreamHandler(instance)
    // Flutter only calls detachFromEngine for a published plugin instance.
    registrar.publish(instance)
  }

  init(registrar: FlutterPluginRegistrar) {
    self.registrar = registrar
    methods = FlutterMethodChannel(
      name: "ugk_trainer/packed_alpha", binaryMessenger: registrar.messenger())
    events = FlutterEventChannel(
      name: "ugk_trainer/packed_alpha/events", binaryMessenger: registrar.messenger())
    super.init()
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    do {
      let args = call.arguments as? [String: Any] ?? [:]
      if call.method == "create" {
        let url = try PackedAlphaSource.resolve(args) { asset in
          Bundle.main.url(forResource: self.registrar.lookupKey(forAsset: asset), withExtension: nil)
        }
        let id = nextID
        nextID += 1
        let player = PackedAlphaPlayer(textures: registrar.textures()) { [weak self] type, fields in
          self?.publish(id: id, type: type, fields: fields)
        }
        players[id] = player
        player.prepare(url: url)
        result(["playerId": id, "textureId": player.textureID])
        return
      }
      guard ["play", "pause", "active", "visible", "position", "dispose"].contains(call.method) else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let id = (args["playerId"] as? NSNumber)?.int64Value, let player = players[id] else {
        result(nil)
        return
      }
      switch call.method {
      case "play": player.play()
      case "pause": player.pause()
      case "active": player.setActive(args["value"] as? Bool == true)
      case "visible": player.setVisible(args["value"] as? Bool == true)
      case "position":
        result(player.position())
        return
      case "dispose":
        players.removeValue(forKey: id)
        pending.removeValue(forKey: id)
        player.dispose()
      default: break
      }
      result(nil)
    } catch {
      result(FlutterError(code: "packed_alpha", message: error.localizedDescription, details: nil))
    }
  }

  private func publish(id: Int64, type: String, fields: [String: Any]) {
    guard players[id] != nil else { return }
    var event = fields
    event["playerId"] = id
    event["type"] = type
    if let sink = sink {
      sink(event)
    } else {
      var entries = pending[id] ?? []
      if let index = entries.firstIndex(where: { $0.type == type }) {
        entries[index] = (type, event)
      } else {
        entries.append((type, event))
      }
      pending[id] = entries
    }
  }

  public func onListen(withArguments arguments: Any?, eventSink: @escaping FlutterEventSink) -> FlutterError? {
    sink = eventSink
    let buffered = pending
    pending.removeAll()
    for (id, entries) in buffered where players[id] != nil {
      for entry in entries { eventSink(entry.event) }
    }
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    return nil
  }

  public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
    let retired = Array(players.values)
    players.removeAll()
    pending.removeAll()
    sink = nil
    retired.forEach { $0.dispose() }
    methods.setMethodCallHandler(nil)
    events.setStreamHandler(nil)
  }
}
