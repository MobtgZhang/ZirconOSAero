# ZirconOS Aero DWM 合成器技术详解

## 一、概述

ZirconOS Aero 合成器（`compositor.zig`）实现了 DWM 风格的离屏合成架构。核心思想是：**每个窗口渲染到独立的 Surface，由合成器在每一帧统一合成到最终帧缓冲**。

这种设计带来以下优势：
- 窗口之间的绘制互不干扰，不会出现经典窗口管理器中的"残影"问题
- 支持 Alpha 混合、玻璃透明、模糊等高级视觉效果
- 光标在独立图层渲染，移动时无需重绘整个场景
- 通过损坏区域追踪，最小化每帧的绘制开销

## 二、Surface 管理

### Surface 结构

每个 Surface 包含以下核心属性：

| 属性 | 类型 | 说明 |
|------|------|------|
| `id` | `u32` | 唯一标识符 |
| `width / height` | `u32` | 尺寸 |
| `x / y` | `i32` | 屏幕上的位置 |
| `z_order` | `i32` | 层叠顺序（小的在下，大的在上） |
| `alpha` | `u8` | 整体透明度（0 = 全透明，255 = 不透明） |
| `blur_radius` | `i32` | 高斯模糊半径（Glass 效果） |
| `flags` | `SurfaceFlags` | 标志位（alpha / shadow / glass / cursor 等） |
| `dirty` | `bool` | 是否需要重绘 |
| `damage_rects` | `[16]Rect` | 损坏区域列表 |

### 特殊 Surface

| Surface | Z-Order | 用途 |
|---------|---------|------|
| 桌面背景 | `DESKTOP_SURFACE_Z` (-0x7FFFFF00) | 最底层 |
| 普通窗口 | 动态分配 | 按激活顺序递增 |
| 光标 | `CURSOR_SURFACE_Z` (0x7FFFFF00) | 始终在最顶层 |

### 生命周期

```
createSurface(w, h, flags)  → 分配 ID，添加到列表
moveSurface(id, x, y)       → 更新位置，标记脏区
setSurfaceGlass(id, true)   → 启用 Glass，设置 alpha 和 blur
destroySurface(id)          → 从列表移除（光标 Surface 不可销毁）
```

## 三、合成流程

### 3.1 帧循环

```
compose() 被每帧调用:
    ┌─ needsRedraw() == false → 跳过
    │
    ├─ 只有光标移动 → composeCursorOnly()  [快速路径]
    │   └─ 恢复旧光标位置背景
    │   └─ 渲染新光标位置
    │   └─ flushRender()
    │
    └─ 场景有变化 → sortSurfacesByZOrder()
        ├─ 有局部损坏 → composePartial()
        │   └─ 仅重绘损坏区域内的 Surface
        └─ 无局部信息 → composeFull()
            └─ 填充桌面背景
            └─ 按 Z-Order 遍历并合成所有可见 Surface
            └─ flushRender()
```

### 3.2 光标快速路径（composeCursorOnly）

这是实现丝滑鼠标的关键优化。当场景没有任何变化、仅光标位置改变时：

1. 计算旧光标位置的恢复区域（prev_x, prev_y, width+2, height+2）
2. 设置裁剪区域为该恢复区域
3. 重绘恢复区域内的桌面背景和覆盖的窗口 Surface
4. 清除裁剪区域
5. 在新位置绘制光标 Surface
6. 刷新帧缓冲

这样，光标移动的开销极低，不受窗口数量影响。

### 3.3 Glass 合成

当 Surface 启用 Glass 效果时（`flags.is_glass == true`）：

```
composeSurface(sfc):
    1. drawShadow()   — 绘制 8px 软阴影（如果 needs_shadow）
    2. drawBlur()     — 对背景区域执行高斯模糊
    3. blitSurface()  — 用 alpha 将 Surface 内容叠加到模糊结果上
```

模糊 + 半透明叠加 = Aero Glass 毛玻璃效果。

## 四、损坏区域追踪（Damage Tracking）

每个 Surface 最多追踪 16 个损坏矩形。合成器据此决定重绘范围：

- **无损坏矩形**：全量重绘（`composeFull`）
- **有损坏矩形**：计算联合包围盒，仅在包围盒范围内重绘（`composePartial`）

```
markDirty(rect)     → 添加损坏矩形到列表
markFullDirty()     → 清空列表，标记整个 Surface 为脏
clearDamage()       → 清空损坏列表，标记为干净
getDamageBounds()   → 返回所有损坏矩形的联合包围盒
```

## 五、VSync 同步

合成器维护 `VsyncState` 来跟踪帧同步状态：

- `frame_target_us`：根据刷新率计算的目标帧间隔（60Hz → 16667µs）
- `last_present_tick`：上一帧提交时间
- `enabled`：是否启用 VSync

在 VSync 模式下，帧呈现与显示器刷新信号对齐，避免画面撕裂。

## 六、统计信息

合成器提供运行时统计（`getStats()`）：

| 指标 | 说明 |
|------|------|
| `total_frames` | 总帧数 |
| `dirty_frames` | 实际执行重绘的帧数 |
| `surfaces_composited` | 累计合成的 Surface 数 |
| `full_redraws` | 全量重绘次数 |
| `partial_redraws` | 局部重绘次数 |
| `glass_surfaces` | 累计执行 Glass 模糊的次数 |
| `cursor_redraws` | 光标快速路径执行次数 |
