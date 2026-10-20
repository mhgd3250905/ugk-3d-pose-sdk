/// 鉴权来源抽象。上线推荐 [RelayAuth]：key 只放在中转 Worker，不进安装包。
library;

abstract interface class AuthProvider {
  /// 每次请求前调用（可异步取/刷新 token）。返回要加到请求上的头。
  Future<Map<String, String>> headers();
}

/// App 内直接持有 API key（开发、内测用）。key 进包可被反编译取出，上线不推荐。
class ApiKeyAuth implements AuthProvider {
  ApiKeyAuth(String key) : _key = key, _read = null;

  /// 每次请求时再读 key（例如从安全存储），便于用户在设置里修改。
  ApiKeyAuth.lazy(Future<String> Function() read) : _key = null, _read = read;

  final String? _key;
  final Future<String> Function()? _read;

  @override
  Future<Map<String, String>> headers() async {
    final k = _key ?? await _read!();
    return {'Authorization': 'Bearer $k'};
  }
}

/// 走远端中转（如 Cloudflare Worker）：Worker 持有真正的 key 并转发到模型服务，
/// App 只带一个可吊销、可限流的 App 令牌（可选），baseUrl 指向 Worker。
class RelayAuth implements AuthProvider {
  RelayAuth({Future<String?> Function()? appToken, this.headerName = 'X-App-Token'})
    : _appToken = appToken;

  final Future<String?> Function()? _appToken;
  final String headerName;

  @override
  Future<Map<String, String>> headers() async {
    final t = await _appToken?.call();
    return t == null || t.isEmpty ? const {} : {headerName: t};
  }
}

/// 不加任何头（上游代理已注入鉴权，例如沙盒冒烟）。
class NoAuth implements AuthProvider {
  const NoAuth();
  @override
  Future<Map<String, String>> headers() async => const {};
}

/// UGK Worker 鉴权：`X-App-Key`（App 级，走 --dart-define，不进仓库）+ `X-Device-Id`（每设备首次生成 UUID、持久保存）。
/// 不带 Authorization。[deviceId] 由 App 实现持久化（SDK 不碰存储）。
class UgkWorkerAuth implements AuthProvider {
  UgkWorkerAuth({required this.appKey, required Future<String> Function() deviceId}) : _deviceId = deviceId;
  final String appKey;
  final Future<String> Function() _deviceId;

  @override
  Future<Map<String, String>> headers() async => {
    if (appKey.isNotEmpty) 'X-App-Key': appKey,
    'X-Device-Id': await _deviceId(),
  };
}
