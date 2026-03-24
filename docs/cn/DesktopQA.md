# 桌面与 DWM 验证清单

## 自动化

- 运行 [`scripts/desktop-qa.sh`](../../scripts/desktop-qa.sh)：内核 `zig build kernel` + `src/desktop/aero` 下 `zig build test`（含合成器 Hit-test 等单元测试）。

## 合成性能（`compositor.getStats()`）

- 关注 `avg_compose_time_us`、`full_redraws` / `partial_redraws` 比例、`glass_surfaces` 与 `cursor_redraws`。
- 宿主可调用 `compositor.shouldThrottleFrame(now_us)` + `compositor.recordPresentTime(now_us)` 做帧间隔控制；`vsync_misses` 在帧间隔过大时递增。

## DWM 关闭回退

- 用户库：`compositor.setDwmEnabled(false)` 后应仍能全量绘制（无模糊时走不透明路径）；内核路径：`display.setDwmGlass(false)` / `dwm.setGlass(false)` 后任务栏与标题栏应退化为纯色填充而非毛玻璃。

## 手动截图回归（建议）

- 默认 Harmony 壁纸 + 玻璃任务栏 + 拖动窗口 + 光标快速移动四类场景；可保存 checksum 或基线 PNG 供对比。
