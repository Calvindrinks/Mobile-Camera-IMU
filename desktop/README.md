# Mobile ZMQ Desktop

Python/uv receiver and Viser viewer for the Godot Android client.

## Run

```bash
UV_CACHE_DIR=.uv-cache UV_PYTHON_INSTALL_DIR=.uv-python uv sync
UV_CACHE_DIR=.uv-cache UV_PYTHON_INSTALL_DIR=.uv-python uv run python ws_viser_server.py --websocket-port 8765
```

Open:

```text
http://127.0.0.1:8080
```

The phone should connect to:

```text
ws://<computer-lan-ip>:8765
```

## CycloneDDS bridge

This bridge receives the same Godot WebSocket packets and republishes them to
CycloneDDS for a remote subscriber.

Prerequisite on macOS:

```bash
brew install cyclonedds
export CYCLONEDDS_HOME="$(brew --prefix cyclonedds)"
```

```bash
UV_CACHE_DIR=.uv-cache UV_PYTHON_INSTALL_DIR=.uv-python uv run python ws_cyclonedds_bridge.py --websocket-port 8766 --domain-id 0
```

Phone endpoint:

```text
ws://<computer-lan-ip>:8766
```

Published topics:

```text
mobile/imu
mobile/image_jpeg
```

The DDS types are defined in `dds_types.py` as `mobile_zmq.MobileImu` and
`mobile_zmq.MobileImageJpeg`.

## Remote Viser over DDS

On the remote machine, subscribe to the DDS topics and show the stream in Viser:

```bash
UV_CACHE_DIR=.uv-cache UV_PYTHON_INSTALL_DIR=.uv-python uv run python dds_viser_viewer.py --domain-id 0 --viser-port 8080
```
