# ZirconOS Aero 丝滑鼠标移动实现原理

## 一、问题背景

在传统操作系统中，鼠标光标的移动往往直接使用 PS/2 中断传来的原始位移值更新屏幕坐标。这种方式存在以下问题：

1. **跳跃感**：PS/2 鼠标的轮询率通常为 125Hz，而显示器刷新率为 60Hz，原始数据在时间上不均匀
2. **低分辨率**：PS/2 鼠标每次报告的位移为整数像素，无法表达更精细的运动意图
3. **撕裂**：如果光标重绘与屏幕刷新不同步，会出现视觉撕裂

ZirconOS Aero 通过 **多层插值 + 独立光标图层 + VSync 同步** 三管齐下，实现丝滑的鼠标移动体验。

## 二、三层平滑架构

丝滑鼠标的实现分布在三个层次：

```
第 1 层：内核驱动层（mouse.zig）
    ↓ 加速 + 灵敏度缩放 + 帧间插值
第 2 层：Aero 输入层（input.zig）
    ↓ 子像素精度追踪 + 线性插值（lerp）
第 3 层：合成器层（compositor.zig）
    ↓ 光标独立图层 + 快速路径渲染
    → 帧缓冲输出
```

### 2.1 第 1 层：内核驱动层

文件：`src/drivers/input/mouse.zig`

PS/2 鼠标中断处理（`handleIrq`）对原始位移进行以下处理：

**加速处理：**
```
speed² = dx² + dy²
if speed² > threshold²:
    dx = dx + dx/2    (150% 加速)
    dy = dy + dy/2
```

**灵敏度缩放：**
```
dx_scaled = dx × sensitivity / 10
dy_scaled = dy × sensitivity / 10
```

**帧间插值（interpolation）：**
当 `interpolation_enabled = true` 时，不直接将缩放后的位移应用到 `(x, y)`，而是：

1. 更新原始目标位置 `(raw_x, raw_y)`
2. 计算从当前位置到目标位置的步进量 `(sub_x, sub_y)`
3. 分 N 步（`interpolation_steps`，默认 4）渐进逼近

```
raw_x += dx_scaled
raw_y += dy_scaled
sub_x = (raw_x - x) / interpolation_steps
sub_y = (raw_y - y) / interpolation_steps
```

`interpolateStep()` 每帧被调用，逐步移动 `(x, y)` 趋向 `(raw_x, raw_y)`：

```
if (还有剩余步数):
    if (最后一步):
        x = raw_x    (精确对齐，消除累积误差)
        y = raw_y
    else:
        x += sub_x
        y += sub_y
```

### 2.2 第 2 层：Aero 输入层

文件：`src/desktop/aero/src/input.zig`

Aero 输入层使用 **子像素精度** 和 **线性插值（lerp）** 进一步平滑光标运动。

**子像素精度：**
```
INTERPOLATION_PRECISION = 256

内部使用 256 倍精度追踪光标位置：
sub_x, sub_y ∈ [-∞, +∞] × 256
display_x = sub_x / 256    (四舍五入到整数像素)
display_y = sub_y / 256
```

**线性插值：**
```
processMouseMove(target_x, target_y):
    tx = target_x × 256
    ty = target_y × 256
    sub_x = sub_x + (tx - sub_x) × lerp_factor / 256
    sub_y = sub_y + (ty - sub_y) × lerp_factor / 256
```

`lerp_factor` 默认 180/256 ≈ 70%，表示每帧追赶目标位置的 70%。

这意味着：
- 大幅移动时：光标跟随速度快（因为距离大，70% 也是大步进）
- 微小移动时：光标有轻微的平滑延迟（视觉上消除抖动）
- 停止移动时：1-3 帧内精确到达目标位置

**速度追踪：**
```
velocity_x = target_x - current_x
velocity_y = target_y - current_y
is_moving = |velocity| > 0
```

速度信息可用于：
- 光标移动动画效果
- 拖拽操作的惯性判断

**收敛检测：**
当 display 位置与 target 位置的距离 ≤ 1 像素时，直接 snap 到目标位置，避免无限逼近但永远到不了的问题。

### 2.3 第 3 层：合成器层

文件：`src/desktop/aero/src/compositor.zig`

合成器为光标维护一个 **独立的 Surface 图层**（CursorLayer），这是丝滑光标的关键优化：

**CursorLayer 结构：**
```
CursorLayer {
    x, y           : 当前光标位置
    prev_x, prev_y : 上一帧光标位置
    surface_id     : 光标 Surface 的 ID
    needs_redraw   : 是否需要重绘
}
```

**快速路径（composeCursorOnly）：**

当只有光标移动，而没有窗口/桌面变化时，合成器进入快速路径：

```
1. 设置裁剪区域为旧光标位置 (prev_x, prev_y, w+2, h+2)
2. 在裁剪区域内重绘桌面背景
3. 在裁剪区域内重绘被覆盖的窗口
4. 清除裁剪区域
5. 在新光标位置绘制光标 Surface
6. flushRender()
```

这个快速路径极大地减少了每帧的绘制量：
- 不需要重绘整个桌面背景
- 不需要遍历所有窗口
- 只处理光标周围的小矩形区域

## 三、内核层平滑光标

文件：`src/drivers/video/display.zig`

内核的 `display.zig` 也实现了独立的平滑光标（`CursorState`），用于在 Aero 主题库加载之前就提供丝滑的光标移动。

**实现方式与 Aero input.zig 相同：**
```
updateSmoothCursor(raw_x, raw_y):
    precision = 256
    tx = raw_x × precision
    ty = raw_y × precision
    sub_x = sub_x + (tx - sub_x) × lerp_factor / 256
    sub_y = sub_y + (ty - sub_y) × lerp_factor / 256
    display_x = sub_x / precision    (四舍五入)
    display_y = sub_y / precision
```

## 四、参数调优

### 灵敏度（sensitivity）

| 值 | 效果 |
|----|------|
| 5 | 低灵敏度，适合高 DPI 鼠标 |
| 10 | 默认值，均衡 |
| 15 | 高灵敏度，快速大范围移动 |
| 20 | 极高灵敏度 |

### 加速阈值（acceleration_threshold）

| 值 | 效果 |
|----|------|
| 3 | 低阈值，轻微移动即加速 |
| 6 | 默认值，中等移动触发加速 |
| 12 | 高阈值，仅快速甩动时加速 |

### 插值因子（lerp_factor）

| 值 | 效果 |
|----|------|
| 128 (50%) | 非常平滑，有明显的追随延迟 |
| 180 (70%) | 默认值，平滑且响应迅速 |
| 220 (86%) | 快速响应，轻微平滑 |
| 255 (100%) | 无平滑，直接到达目标 |

### 插值步数（interpolation_steps）

| 值 | 效果 |
|----|------|
| 1 | 无内核层插值 |
| 4 | 默认值，4 步渐进 |
| 8 | 极致平滑，适合高刷新率 |

## 五、配置

在 `src/config/desktop.conf` 中配置：

```ini
[mouse]
sensitivity = 10
acceleration = true
acceleration_threshold = 6
smooth_scrolling = true
interpolation_enabled = true
interpolation_steps = 4
poll_rate = 125
cursor_shadow = true
```

在 Shell 初始化时通过 `ShellConfig` 传递：

```zig
const config = ShellConfig{
    .smooth_cursor = true,
    .cursor_lerp_factor = 180,
    .vsync_enabled = true,
};
```

## 六、性能特征

| 操作 | 开销 |
|------|------|
| PS/2 中断处理 + 插值 | ~2µs |
| input.zig lerp 计算 | ~1µs |
| composeCursorOnly（快速路径） | ~50µs（仅光标周围小区域） |
| composeFull（全量重绘） | ~2000µs（1280×800, 取决于窗口数） |

光标移动时，99% 的帧走快速路径，开销极低。
