# CZstd — 内置的 zstd 解压器

DeepSeek Harness 的会话正文（`~/.dsh/sessions/**/session*.jsonl.zstd`）是 **zstd 压缩**的，
而 macOS 的 `Compression` 框架只提供 lzfse / lz4 / zlib，**不含 zstd**。

Quota Bar 需要读这些日志来按消息时间戳精确归日（DSH 的未压缩缓存只有会话累计值，
跨天会话会把整段用量算到会话开始日，导致「今日用量」为 0）。

## 为什么内置而不是依赖外部

- **不依赖 Homebrew**：若链接 `/opt/homebrew/lib/libzstd`，用户必须装 Homebrew 才能运行，
  与「下载解压即用」的发布方式冲突；
- **不依赖 DSH 内部实现**：DSH 的 node 运行时虽然可能支持 zstd，但那是它的私有细节，
  版本升级即可能失效；
- 单文件解压器编译进 app 后，**零外部依赖**，离线可用。

## 来源

由 zstd 官方 `build/single_file_libs/combine.py` 生成（仅解压，不含压缩）：

```
zstd v1.5.7 (facebook/zstd)
cd zstd/build/single_file_libs
python3 combine.py -r ../../lib -x legacy/zstd_legacy.h -o zstddeclib.c zstddeclib-in.c
```

- `zstddeclib.c` — 生成的单文件解压器
- `include/zstd.h`、`include/zstd_errors.h` — 公开头文件
- `VERSION` — 上游版本号
- `LICENSE` — BSD / GPLv2 双许可（上游原文）

升级方式：重复上述命令，替换 `zstddeclib.c` 与两个头文件，并更新 `VERSION`。
