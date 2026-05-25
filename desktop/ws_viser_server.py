from __future__ import annotations

import argparse
import asyncio
import json
import time
from collections import deque
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import imageio.v3 as iio
import numpy as np
import viser
import websockets
from websockets.server import WebSocketServerProtocol


@dataclass
class ServerConfig:
    websocket_host: str = "0.0.0.0"
    websocket_port: int = 8765
    viser_host: str = "0.0.0.0"
    viser_port: int = 8080
    save: bool = False
    data_dir: Path = Path("data")
    record_seconds: float = 5.0


def xyzw_to_wxyz(values: list[float]) -> tuple[float, float, float, float]:
    if len(values) != 4:
        raise ValueError("quaternion_xyzw must contain four numbers")
    x, y, z, w = (float(v) for v in values)
    return (w, x, y, z)


def timestamp_seconds(packet: dict[str, Any]) -> float:
    timestamp_msec = packet.get("timestamp_msec")
    if timestamp_msec is None:
        return time.time()
    return float(timestamp_msec) / 1000.0


def vector3(values: Any, field_name: str) -> np.ndarray:
    array = np.asarray(values, dtype=np.float32)
    if array.shape != (3,):
        raise ValueError(f"{field_name} must contain three numbers")
    return array


@dataclass
class ImuSample:
    timestamp_sec: float
    values: np.ndarray


class TimedTrackRecorder:
    def __init__(self, data_dir: Path, default_duration_sec: float) -> None:
        self.data_dir = data_dir
        self.default_duration_sec = default_duration_sec
        self.track_dir: Path | None = None
        self.image_dir: Path | None = None
        self.imu_dir: Path | None = None
        self.duration_sec = default_duration_sec

        self.image_count = 0
        self.imu_interval_count = 0
        self.dropped_imu_count = 0
        self.pending_imu: deque[ImuSample] = deque()
        self.start_timestamp_sec: float | None = None
        self.last_image_timestamp_sec: float | None = None
        self.waiting_for_first_image = False
        self.recording_active = False
        self.recording_complete = False

    def start(self, duration_sec: float | None = None) -> bool:
        if self.recording_active or self.waiting_for_first_image:
            return False

        self.duration_sec = (
            self.default_duration_sec if duration_sec is None else max(0.001, duration_sec)
        )
        self.track_dir = self._next_track_dir()
        self.image_dir = self.track_dir / "images"
        self.imu_dir = self.track_dir / "imu"
        self.image_dir.mkdir(parents=True)
        self.imu_dir.mkdir(parents=True)

        self.image_count = 0
        self.imu_interval_count = 0
        self.dropped_imu_count = 0
        self.pending_imu.clear()
        self.start_timestamp_sec = None
        self.last_image_timestamp_sec = None
        self.waiting_for_first_image = True
        self.recording_active = False
        self.recording_complete = False
        print(
            f"[Recorder] waiting for first image, then recording "
            f"{self.duration_sec:g}s to {self.track_dir}"
        )
        return True

    def _next_track_dir(self) -> Path:
        self.data_dir.mkdir(parents=True, exist_ok=True)
        index = 1
        while True:
            track_dir = self.data_dir / f"track{index}"
            if not track_dir.exists():
                return track_dir
            index += 1

    def add_imu(self, packet: dict[str, Any]) -> None:
        if not self.waiting_for_first_image and not self.recording_active:
            return

        try:
            timestamp_sec = timestamp_seconds(packet)
            acc = vector3(packet.get("accelerometer"), "accelerometer")
            gyro_rad = vector3(packet.get("gyroscope"), "gyroscope")
        except (TypeError, ValueError) as exc:
            print(f"[Recorder] skip bad IMU packet: {exc}")
            return

        gyro_deg = np.rad2deg(gyro_rad).astype(np.float32)
        self.pending_imu.append(ImuSample(timestamp_sec, np.concatenate([acc, gyro_deg])))

        if not self.recording_active or self.last_image_timestamp_sec is None:
            return
        while self.pending_imu and self.pending_imu[0].timestamp_sec < self.last_image_timestamp_sec:
            self.pending_imu.popleft()
            self.dropped_imu_count += 1

    def add_image(self, header: dict[str, Any], image: np.ndarray) -> None:
        if not self.waiting_for_first_image and not self.recording_active:
            return

        image_timestamp_sec = timestamp_seconds(header)
        if self.start_timestamp_sec is None:
            self.start_timestamp_sec = image_timestamp_sec
            self.waiting_for_first_image = False
            self.recording_active = True
        if image_timestamp_sec - self.start_timestamp_sec > self.duration_sec:
            self.recording_active = False
            self.recording_complete = True
            print(
                "[Recorder] complete: "
                f"{self.image_count} images, {self.imu_interval_count} imu files "
                f"in {self.track_dir}"
            )
            return

        if self.last_image_timestamp_sec is not None:
            self._save_imu_interval(self.last_image_timestamp_sec, image_timestamp_sec)

        if self.image_dir is None:
            raise RuntimeError("recorder image directory is not initialized")
        image_path = self.image_dir / f"{self.image_count}.png"
        iio.imwrite(image_path, image)
        self.image_count += 1
        self.last_image_timestamp_sec = image_timestamp_sec

    def _save_imu_interval(self, start_sec: float, end_sec: float) -> None:
        interval_values: list[np.ndarray] = []
        while self.pending_imu and self.pending_imu[0].timestamp_sec < start_sec:
            self.pending_imu.popleft()
            self.dropped_imu_count += 1
        while self.pending_imu and self.pending_imu[0].timestamp_sec < end_sec:
            sample = self.pending_imu.popleft()
            if sample.timestamp_sec >= start_sec:
                interval_values.append(sample.values)

        if interval_values:
            array = np.vstack(interval_values).astype(np.float32)
        else:
            array = np.empty((0, 6), dtype=np.float32)
        if self.imu_dir is None:
            raise RuntimeError("recorder IMU directory is not initialized")
        np.save(self.imu_dir / f"{self.imu_interval_count}.npy", array)
        self.imu_interval_count += 1

    def summary(self) -> str:
        if self.waiting_for_first_image:
            state = "armed"
        elif self.recording_active:
            state = "recording"
        elif self.recording_complete:
            state = "done"
        else:
            state = "idle"
        track = self.track_dir.name if self.track_dir is not None else "-"
        return (
            f"{state} track={track} duration={self.duration_sec:g}s "
            f"images={self.image_count} "
            f"imu_files={self.imu_interval_count} "
            f"queued_imu={len(self.pending_imu)} "
            f"dropped_imu={self.dropped_imu_count}"
        )


class ViserPhoneScene:
    def __init__(
        self,
        host: str,
        port: int,
        recorder: TimedTrackRecorder | None,
    ) -> None:
        self.server = viser.ViserServer(host=host, port=port)
        self.server.scene.world_axes.visible = True
        self.server.scene.add_grid("/floor", width=2.0, height=2.0)
        self.phone_frame = self.server.scene.add_frame(
            "/phone",
            axes_length=0.25,
            axes_radius=0.01,
            position=(0.0, 0.0, 0.25),
        )
        self.server.scene.add_box(
            "/phone/body",
            dimensions=(0.08, 0.16, 0.015),
            color=(45, 194, 165),
            position=(0.0, 0.0, 0.25),
        )
        self.status = self.server.gui.add_text("Last packet", initial_value="none")
        self.image_status = self.server.gui.add_text("Last image", initial_value="none")
        self.record_status = self.server.gui.add_text(
            "Recorder",
            initial_value=recorder.summary() if recorder is not None else "disabled",
        )
        if recorder is not None:
            self.record_seconds = self.server.gui.add_number(
                "Record seconds",
                initial_value=recorder.default_duration_sec,
                min=0.1,
                step=0.1,
            )
            self.record_button = self.server.gui.add_button("Start recording")

            @self.record_button.on_click
            def _(_: Any) -> None:
                recorder.start(float(self.record_seconds.value))
                self.record_status.value = recorder.summary()

        self.camera_debug = self.server.gui.add_text("Camera debug", initial_value="none")
        self.recorder = recorder
        self.last_packet_time = 0.0
        self.packet_times: deque[float] = deque()
        self.image_times: deque[float] = deque()
        self.last_scene_update = 0.0
        self.image_handle = None
        self.binary_image_count = 0
        self.last_binary_size = 0

    def update_from_packet(self, packet: dict[str, Any]) -> None:
        if packet.get("type") != "imu":
            return

        if self.recorder is not None:
            self.recorder.add_imu(packet)
            self.record_status.value = self.recorder.summary()

        now = time.time()
        self.packet_times.append(now)
        while self.packet_times and now - self.packet_times[0] > 1.0:
            self.packet_times.popleft()
        hz = float(len(self.packet_times))

        try:
            wxyz = xyzw_to_wxyz(packet["quaternion_xyzw"])
        except (KeyError, TypeError, ValueError) as exc:
            self.status.value = f"bad packet: {exc}"
            return

        if now - self.last_scene_update >= 1.0 / 60.0:
            self.phone_frame.wxyz = wxyz
            self.last_scene_update = now

        self.last_packet_time = now
        gravity = np.asarray(packet.get("gravity", [0.0, 0.0, 0.0]), dtype=float)
        self.status.value = (
            f"seq={packet.get('seq', '?')}  "
            f"rate={hz:0.1f} Hz  "
            f"gravity={np.round(gravity, 3).tolist()}"
        )

    def update_from_image(self, header: dict[str, Any], jpeg: bytes) -> None:
        now = time.time()
        self.binary_image_count += 1
        self.last_binary_size = len(jpeg)
        self.image_times.append(now)
        while self.image_times and now - self.image_times[0] > 1.0:
            self.image_times.popleft()
        hz = float(len(self.image_times))

        try:
            image = iio.imread(jpeg)
        except Exception as exc:
            self.image_status.value = f"bad image: {exc}"
            return

        if self.recorder is not None:
            self.recorder.add_image(header, image)
            self.record_status.value = self.recorder.summary()

        height, width = image.shape[:2]
        render_height = 0.45
        render_width = render_height * width / max(height, 1)
        if self.image_handle is None:
            self.image_handle = self.server.scene.add_image(
                "/phone/camera",
                image=image,
                render_width=render_width,
                render_height=render_height,
                position=(0.0, 0.45, 0.45),
                wxyz=(0.7071068, 0.7071068, 0.0, 0.0),
                jpeg_quality=80,
            )
        else:
            self.image_handle.image = image

        self.image_status.value = (
            f"seq={header.get('seq', '?')}  "
            f"rate={hz:0.1f} Hz  "
            f"shape={width}x{height}"
        )

    def update_debug(self, packet: dict[str, Any]) -> None:
        compact = {
            "feed_count": packet.get("feed_count"),
            "feed_id": packet.get("feed_id"),
            "feed_name": packet.get("feed_name"),
            "feed_position": packet.get("feed_position"),
            "feed_datatype": packet.get("feed_datatype"),
            "feed_active": packet.get("feed_active"),
            "texture_active": packet.get("texture_active"),
            "texture_feed_id": packet.get("texture_feed_id"),
            "texture_which_feed": packet.get("texture_which_feed"),
            "backend": packet.get("backend"),
            "last_image_size": packet.get("last_image_size"),
            "last_jpeg_size": packet.get("last_jpeg_size"),
            "empty_image_count": packet.get("empty_image_count"),
            "native_has_permission": packet.get("native_has_permission"),
            "native_has_frame": packet.get("native_has_frame"),
            "viser_image_packets": self.binary_image_count,
            "viser_last_jpeg_size": self.last_binary_size,
        }
        text = json.dumps(compact, ensure_ascii=False)
        self.camera_debug.value = text
        print(f"[Camera debug] {text}")


def decode_binary_image(message: bytes) -> tuple[dict[str, Any], bytes] | None:
    if len(message) < 8 or not message.startswith(b"IMG1"):
        return None
    header_size = int.from_bytes(message[4:8], byteorder="little", signed=False)
    header_start = 8
    header_end = header_start + header_size
    if header_end > len(message):
        return None
    header = json.loads(message[header_start:header_end].decode("utf-8"))
    return header, message[header_end:]


async def handle_client(
    websocket: WebSocketServerProtocol,
    scene: ViserPhoneScene,
) -> None:
    print(f"WebSocket client connected: {websocket.remote_address}")
    try:
        async for message in websocket:
            if isinstance(message, bytes):
                image_message = decode_binary_image(message)
                if image_message is not None:
                    header, jpeg = image_message
                    scene.update_from_image(header, jpeg)
                    continue
                try:
                    message = message.decode("utf-8")
                except UnicodeDecodeError:
                    scene.image_status.value = "bad binary packet"
                    continue
            if isinstance(message, str):
                try:
                    packet = json.loads(message)
                except json.JSONDecodeError:
                    scene.status.value = "bad packet: invalid JSON"
                    continue
                if packet.get("type") == "debug":
                    scene.update_debug(packet)
                else:
                    scene.update_from_packet(packet)
    finally:
        print(f"WebSocket client disconnected: {websocket.remote_address}")


async def run_async(config: ServerConfig) -> None:
    recorder = (
        TimedTrackRecorder(config.data_dir, config.record_seconds)
        if config.save
        else None
    )
    scene = ViserPhoneScene(config.viser_host, config.viser_port, recorder)
    print(f"Viser available on http://127.0.0.1:{config.viser_port}")
    print(
        "WebSocket listening on "
        f"ws://{config.websocket_host}:{config.websocket_port}"
    )
    if recorder is not None:
        print(
            "Recording controls enabled in Viser. "
            f"Tracks will be written under {config.data_dir}."
        )
    else:
        print("Recording controls disabled. Pass --save to enable recording.")

    async with websockets.serve(
        lambda websocket: handle_client(websocket, scene),
        config.websocket_host,
        config.websocket_port,
        max_size=None,
    ):
        await asyncio.Future()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--websocket-host", default="0.0.0.0")
    parser.add_argument("--websocket-port", type=int, default=8765)
    parser.add_argument("--viser-host", default="0.0.0.0")
    parser.add_argument("--viser-port", type=int, default=8080)
    parser.add_argument(
        "--save",
        action="store_true",
        help="Record image PNGs and timestamp-matched IMU .npy files.",
    )
    parser.add_argument(
        "--data-dir",
        type=Path,
        default=Path(__file__).resolve().parent / "data",
        help="Directory containing images/ and imu/ output folders.",
    )
    parser.add_argument(
        "--record-seconds",
        type=float,
        default=5.0,
        help="Capture duration measured from the first saved image timestamp.",
    )
    args = parser.parse_args()
    asyncio.run(
        run_async(
            ServerConfig(
                websocket_host=args.websocket_host,
                websocket_port=args.websocket_port,
                viser_host=args.viser_host,
                viser_port=args.viser_port,
                save=args.save,
                data_dir=args.data_dir,
                record_seconds=args.record_seconds,
            )
        )
    )


if __name__ == "__main__":
    main()
