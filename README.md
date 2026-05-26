# Mobile WebSocket Viser

这个仓库包含两个子项目：

- `godot/`：手机端 Godot 4 Android app，采集 IMU 和相机图像，通过 WebSocket 发布数据。
- `desktop/`：电脑端 Python/uv 项目，启动 WebSocket server，并用 Viser 可视化姿态、图像和调试状态。

## 应用指南

1. 去 Release 下载对应版本APK
2. 确认Android 手机和电脑在同一网络，填写电脑端IP地址，默认是 TCP `8765` 入站。
3. 先Connect 再 打开stream

没有连接到 WebSocket 服务时，Godot app 会进入 dry-run 模式，把即将发送的 JSON 打印到输出窗口，便于先验证 IMU 数据和四元数计算。

## 电脑端

```bash
cd desktop
uv sync
uv run python ws_viser_server.py --websocket-port 8765
```

若想带录制功能
```bash
cd desktop
uv run python ws_viser_server.py --websocket-port 8765 --save
```

打开 Viser 页面：默认渲染相机·

```text
http://127.0.0.1:8080
```

如果手机和电脑在同一个 Wi-Fi，手机端 endpoint 填：

```text
ws://电脑局域网IP:8765
```

例如：

```text
ws://192.168.0.16:8765
```



## 当前消息格式

```json
{
  "type": "imu",
  "seq": 1,
  "timestamp_msec": 123456,
  "imu_frame": "camera_body",
  "screen_orientation": "portrait",
  "quaternion_xyzw": [0.0, 0.0, 0.0, 1.0],
  "gravity": [0.0, -9.8, 0.0],
  "gyroscope": [0.0, 0.0, 0.0],
  "accelerometer": [0.0, 0.0, 0.0]
}
```

## 本项目的camera_body坐标系

`viser` 的 scene frame API 使用 `wxyz` 四元数顺序，所以电脑端会把 Godot 的 `xyzw` 转成 `wxyz`。

`gravity`、`accelerometer` 和 `gyroscope` 已在 Godot 端转换到 `camera_body`：

```text
X: Android/Godot X
Y: -Android/Godot Y
Z: -Android/Godot Z
```

Godot Android 源码对 `accelerometer/gravity` 和 `gyroscope` 的符号处理不同，因此发送前分别使用：

```text
accelerometer/gravity: [-godot.x,  godot.y,  godot.z]
gyroscope:             [ godot.x, -godot.y, -godot.z]
```

图像使用 WebSocket 二进制包发送：

```text
IMG1 + uint32_le(json_header_size) + json_header + jpeg_bytes
```

目前已支持屏幕朝向转变，在imu和图像同时对轴系翻转，实现支持横屏录制。


## CycloneDDS

电脑端也提供 WebSocket 到 CycloneDDS 的本地 bridge：

```bash
brew install cyclonedds
export CYCLONEDDS_HOME="$(brew --prefix cyclonedds)"
```

```bash
cd desktop
uv run python ws_cyclonedds_bridge.py --websocket-port 8766 --domain-id 0
```

手机端 endpoint 填 `ws://电脑局域网IP:8766`。bridge 会发布：

```text
mobile/imu
mobile/image_jpeg
```

DDS 类型定义在 `desktop/dds_types.py`，远程 `calvinhou` 端订阅时保持相同 typename 和 topic 即可。

远程 Viser 查看：

```bash
cd ~/Documents/mobile_zmq_client
uv run python dds_viser_viewer.py --domain-id 0 --viser-port 8080
```

## 自己导出

目前本项目已经发布releasee版本apk。为维护项目大小gitignore不记录导出模版，自己导出需要自行添加模版。

Debug APK 示例：

```bash
godot --path /Users/tax/Documents/mobile-zmq/godot --headless --export-debug Android builds/android/mobile_zmq_v0.3.2.apk
```

NativeCamera Android 插件需要 Gradle Android export 才能把 `.aar` 打进 APK。`godot/android/`、`godot/builds/`、导出模板和 keystore 都是本地产物，不提交。

相机使用 NativeCamera Plugin v3.0，请求 `3840x2160 @ 30Hz`，并启用插件端 `auto_upright`，避免在 GDScript 中逐帧旋转图像。Viser 页面提供 `Render images` 开关；关闭后仍接收图像包并统计频率，但会跳过 JPEG 解码和 Viser 图像刷新。
