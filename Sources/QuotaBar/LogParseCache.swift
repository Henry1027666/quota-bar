import Foundation

/// 日志解析结果的磁盘缓存。
///
/// 冷启动时全量解压/解析数百个日志文件（Codex 的 .jsonl.zst、DSH 的 .jsonl.zstd、
/// Kimi 的 wire.jsonl）需要一分钟左右，而解析缓存原先只驻留内存、重启即失效。
/// 这些日志内容只增不改，把解析结果（按小时归并的 token 聚合）以
/// 「路径 + mtime + size」为键落盘到 ~/Library/Caches/QuotaBar/logparse/ 后，
/// 重启只需 stat + 查索引，只有新增/变化的文件才重新解析，冷启动降到秒级。
/// 缓存损坏或缺失时静默回退全量解析；源文件被清理（归档/删除）的条目在加载时修剪。
final class LogParseCache<Value: Codable & Sendable>: @unchecked Sendable {
    struct Entry: Codable {
        var mtime: Double
        var size: UInt64
        var value: Value
    }

    private let url: URL
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var pendingSave: DispatchWorkItem?

    init(name: String) {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches")
        self.url = base.appendingPathComponent("QuotaBar/logparse/\(name).json", isDirectory: false)
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) else { return }
        // 修剪：源文件已不存在的条目（Codex 压缩迁移、DSH 清理等）直接丢弃
        let fm = FileManager.default
        entries = decoded.filter { fm.fileExists(atPath: $0.key) }
        LogParseCacheRegistry.register { [weak self] in self?.flushNow() }
    }

    /// 命中且 mtime/size 与磁盘上的文件一致时返回缓存的解析结果，否则 nil。
    func value(for path: String, mtime: Date, size: UInt64) -> Value? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[path],
              entry.mtime == mtime.timeIntervalSince1970,
              entry.size == size else { return nil }
        return entry.value
    }

    /// 写入（或更新）一条解析结果；2 秒内多次写入合并为一次落盘。
    func insert(_ value: Value, for path: String, mtime: Date, size: UInt64) {
        lock.lock()
        entries[path] = Entry(mtime: mtime.timeIntervalSince1970, size: size, value: value)
        lock.unlock()
        scheduleSave()
    }

    private func scheduleSave() {
        lock.lock()
        pendingSave?.cancel()
        let item = DispatchWorkItem { [self] in saveNow() }
        pendingSave = item
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2, execute: item)
    }

    /// 取消防抖、立即落盘（应用终止时由 LogParseCacheRegistry.flushAll 调用）。
    private func flushNow() {
        lock.lock()
        pendingSave?.cancel()
        pendingSave = nil
        lock.unlock()
        saveNow()
    }

    private func saveNow() {
        lock.lock()
        let snapshot = entries
        lock.unlock()
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let tmp = url.appendingPathExtension("tmp")
            try data.write(to: tmp, options: .atomic)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } catch {
            // 缓存写失败不影响主流程，下次启动回退全量解析
        }
    }
}

/// LogParseCache 各泛型特化共享的注册表：泛型的 static 存储是按特化分开的，
/// 而应用终止时要能一次性 flush 所有实例，因此注册表放在非泛型类型上。
enum LogParseCacheRegistry {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var flushClosures: [() -> Void] = []

    static func register(_ closure: @escaping () -> Void) {
        lock.lock()
        flushClosures.append(closure)
        lock.unlock()
    }

    /// 应用终止前调用：所有缓存立即落盘。
    /// 不写也不影响正确性（下次启动回退全量解析），只是少一次重启加速。
    static func flushAll() {
        lock.lock()
        let closures = flushClosures
        lock.unlock()
        for closure in closures { closure() }
    }
}
