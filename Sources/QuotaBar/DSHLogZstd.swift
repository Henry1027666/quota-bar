import CZstd
import Foundation

/// 用内置的 zstd 单文件解压器解开 DSH 的会话正文（`*.jsonl.zstd`）。
///
/// 为什么需要它：DSH 的 `session_projcache` 只保存**会话累计** token（`tokenUsage.totals`），
/// 没有按日明细。一个会话跨天时（会话可连续开好几天），把累计值算到会话开始日会让
/// 「今日用量」失真（实测某会话 10-13 开始、10-14 仍在使用，全部 46 万 token 都被算到 10-13，
/// 导致当日显示 0，而 10-14 实际有 13 万）。
/// 压缩正文里每条 `assistant/message` 都带毫秒时间戳，是唯一能精确归日的数据源。
///
/// 解压实现：调用随包编译的 zstd 官方单文件解压器（Sources/CZstd），
/// 不依赖 Homebrew 或任何系统外组件。
enum DSHLogZstd {
    /// 解压整个 `.zstd` 文件并返回 UTF-8 文本；失败返回 nil。
    /// 文件可达数 MB（解压后十余 MB），逐块输出避免一次性申请过大的缓冲。
    static func decompressText(at url: URL) -> String? {
        guard let compressed = try? Data(contentsOf: url), !compressed.isEmpty else { return nil }
        guard let raw = decompress(compressed) else { return nil }
        return String(data: raw, encoding: .utf8)
    }

    /// 解压字节流（流式，支持未知解压后长度）。
    static func decompress(_ compressed: Data) -> Data? {
        guard let stream = ZSTD_createDStream() else { return nil }
        defer { ZSTD_freeDStream(stream) }
        guard ZSTD_isError(ZSTD_initDStream(stream)) == 0 else { return nil }

        let bufferSize = 1 << 20   // 1 MiB/块
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        var output = Data()
        let ok: Bool = compressed.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Bool in
            guard let base = src.baseAddress else { return false }
            var input = ZSTD_inBuffer(src: base, size: compressed.count, pos: 0)
            while input.pos < input.size {
                var out = ZSTD_outBuffer(dst: buffer, size: bufferSize, pos: 0)
                let remaining = ZSTD_decompressStream(stream, &out, &input)
                guard ZSTD_isError(remaining) == 0 else { return false }
                if out.pos > 0 { output.append(buffer, count: out.pos) }
            }
            return true
        }
        return ok ? output : nil
    }
}
