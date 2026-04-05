# 大页 / ASLR / SMP 审查 / RISC-V UEFI（extra 里程碑）

本页汇总 content1.1「中低优先级」工程项，便于排期与检索。

| 主题 | 现状 / 下一步 |
|------|----------------|
| **大页（2MiB/1GiB）** | x86_64 恒等映射路径已优先 2MiB（`vm.mapIdentityByteRange`）；每进程用户区大页与拆分策略见 `paging.zig` 与契约矩阵。 |
| **ASLR** | 用户区基址随机化未完整；依赖每进程独立 CR3 + VAD/区段分配策略演进。 |
| **SMP 全路径竞争** | AP 已在线（`ap_entry`）；端口/IPC 细粒度锁见 `port.zig` 头注释；对象头计数已原子化（`ob/object.zig`）。 |
| **RISC-V UEFI** | 受 Zig PE/COFF 与引导链限制，见 `build.zig` 注释与 `docs/en/Boot.md`。 |
