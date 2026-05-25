from __future__ import annotations

import argparse
import asyncio
import json
import time
from collections import deque
from dataclasses import dataclass
from typing import Any

import websockets
from cyclonedds.domain import DomainParticipant
from cyclonedds.pub import DataWriter, Publisher
from cyclonedds.topic import Topic
from websockets.server import WebSocketServerProtocol

from dds_types import MobileImageJpeg, MobileImu
from ws_viser_server import decode_binary_image


@dataclass
class BridgeConfig:
    websocket_host: str = "0.0.0.0"
    websocket_port: int = 8766
    domain_id: int = 0
    imu_topic: str = "mobile/imu"
    image_topic: str = "mobile/image_jpeg"
    stats_interval_sec: float = 1.0


class CycloneDdsBridge:
    def __init__(self, config: BridgeConfig) -> None:
        self.config = config
        self.participant = DomainParticipant(config.domain_id)
        self.publisher = Publisher(self.participant)
        self.imu_writer = DataWriter(
            self.publisher,
            Topic(self.participant, config.imu_topic, MobileImu),
        )
        self.image_writer = DataWriter(
            self.publisher,
            Topic(self.participant, config.image_topic, MobileImageJpeg),
        )
        self.imu_times: deque[float] = deque()
        self.image_times: deque[float] = deque()
        self.last_stats_time = 0.0
        self.last_image_size = 0

    def publish_imu(self, packet: dict[str, Any]) -> None:
        msg = MobileImu(
            seq=int(packet.get("seq", 0)),
            timestamp_msec=int(packet.get("timestamp_msec", 0)),
            quaternion_xyzw=_float_list(packet.get("quaternion_xyzw"), 4),
            gravity=_float_list(packet.get("gravity"), 3),
            gyroscope=_float_list(packet.get("gyroscope"), 3),
            accelerometer=_float_list(packet.get("accelerometer"), 3),
        )
        self.imu_writer.write(msg)
        self._record(self.imu_times)
        self._maybe_print_stats()

    def publish_image(self, header: dict[str, Any], jpeg: bytes) -> None:
        msg = MobileImageJpeg(
            seq=int(header.get("seq", 0)),
            timestamp_msec=int(header.get("timestamp_msec", 0)),
            width=int(header.get("width", 0)),
            height=int(header.get("height", 0)),
            encoding=str(header.get("encoding", "jpeg")),
            jpeg=list(jpeg),
        )
        self.image_writer.write(msg)
        self.last_image_size = len(jpeg)
        self._record(self.image_times)
        self._maybe_print_stats()

    def _record(self, samples: deque[float]) -> None:
        now = time.time()
        samples.append(now)
        while samples and now - samples[0] > 1.0:
            samples.popleft()

    def _maybe_print_stats(self) -> None:
        now = time.time()
        if now - self.last_stats_time < self.config.stats_interval_sec:
            return
        self.last_stats_time = now
        print(
            "DDS publish "
            f"imu={len(self.imu_times):.1f}Hz "
            f"image={len(self.image_times):.1f}Hz "
            f"last_jpeg={self.last_image_size}B "
            f"topics=({self.config.imu_topic}, {self.config.image_topic})"
        )


def _float_list(value: Any, expected_len: int) -> list[float]:
    if not isinstance(value, list):
        return [0.0] * expected_len
    values = [float(item) for item in value[:expected_len]]
    if len(values) < expected_len:
        values.extend([0.0] * (expected_len - len(values)))
    return values


async def handle_client(
    websocket: WebSocketServerProtocol,
    bridge: CycloneDdsBridge,
) -> None:
    print(f"WebSocket client connected: {websocket.remote_address}")
    try:
        async for message in websocket:
            if isinstance(message, bytes):
                image_message = decode_binary_image(message)
                if image_message is None:
                    print("Ignoring unknown binary packet")
                    continue
                header, jpeg = image_message
                bridge.publish_image(header, jpeg)
                continue

            try:
                packet = json.loads(message)
            except json.JSONDecodeError as exc:
                print(f"Ignoring invalid JSON packet: {exc}")
                continue

            if packet.get("type") == "imu":
                bridge.publish_imu(packet)
    finally:
        print(f"WebSocket client disconnected: {websocket.remote_address}")


async def run_async(config: BridgeConfig) -> None:
    bridge = CycloneDdsBridge(config)
    print(
        "WebSocket listening on "
        f"ws://{config.websocket_host}:{config.websocket_port}"
    )
    print(
        "CycloneDDS publishing "
        f"domain={config.domain_id} "
        f"imu_topic={config.imu_topic} "
        f"image_topic={config.image_topic}"
    )

    async with websockets.serve(
        lambda websocket: handle_client(websocket, bridge),
        config.websocket_host,
        config.websocket_port,
        max_size=None,
    ):
        await asyncio.Future()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--websocket-host", default="0.0.0.0")
    parser.add_argument("--websocket-port", type=int, default=8766)
    parser.add_argument("--domain-id", type=int, default=0)
    parser.add_argument("--imu-topic", default="mobile/imu")
    parser.add_argument("--image-topic", default="mobile/image_jpeg")
    parser.add_argument("--stats-interval-sec", type=float, default=1.0)
    args = parser.parse_args()
    asyncio.run(
        run_async(
            BridgeConfig(
                websocket_host=args.websocket_host,
                websocket_port=args.websocket_port,
                domain_id=args.domain_id,
                imu_topic=args.imu_topic,
                image_topic=args.image_topic,
                stats_interval_sec=args.stats_interval_sec,
            )
        )
    )


if __name__ == "__main__":
    main()
