# Mobile WebSocket Viser

这个仓库是一个最小可落地骨架：

- 手机端：Godot 4 Android app，采集 `Input.get_gravity()`、`Input.get_gyroscope()`、`Input.get_accelerometer()`，用互补滤波估计姿态四元数。
- 通信层：Godot 内置 WebSocket，发送 JSON 包。
- 电脑端：Python `websockets` 接收数据，用 `viser` 显示手机坐标系和姿态。

## 电脑端运行

```bash
UV_CACHE_DIR=.uv-cache UV_PYTHON_INSTALL_DIR=.uv-python uv sync
UV_CACHE_DIR=.uv-cache UV_PYTHON_INSTALL_DIR=.uv-python uv run python desktop/ws_viser_server.py --websocket-port 8765
```

打开 Viser 页面：

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

## Godot 端运行

1. 用 Godot 4.6 打开本目录。
2. 运行电脑端 `desktop/ws_viser_server.py`。
3. Android 导出时确认手机和电脑在同一网络，电脑防火墙允许 TCP `8765` 入站。

没有连接到 WebSocket 服务时，Godot app 会进入 dry-run 模式，把即将发送的 JSON 打印到输出窗口，便于先验证 IMU 数据和四元数计算。

## 当前消息格式

```json
{
  "type": "imu",
  "seq": 1,
  "timestamp_msec": 123456,
  "quaternion_xyzw": [0.0, 0.0, 0.0, 1.0],
  "gravity": [0.0, -9.8, 0.0],
  "gyroscope": [0.0, 0.0, 0.0],
  "accelerometer": [0.0, 0.0, 0.0]
}
```

`viser` 的 scene frame API 使用 `wxyz` 四元数顺序，所以电脑端会把 Godot 的 `xyzw` 转成 `wxyz`。

## 下一步

- 接入 Android Native Camera Plugin 后，把图像压缩成 JPEG，再用 WebSocket 二进制包或单独图像通道发送。
- 如果需要低延迟图像流，建议 IMU 继续走 WebSocket，图像改走 WebRTC、RTSP 或 MJPEG，电脑端只把最新图像贴到 Viser `add_camera_frustum()` 或 `add_image()`。
