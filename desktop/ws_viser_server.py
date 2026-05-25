from __future__ import annotations

import argparse
import asyncio
import json
import time
from collections import deque
from dataclasses import dataclass
from typing import Any

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


def xyzw_to_wxyz(values: list[float]) -> tuple[float, float, float, float]:
    if len(values) != 4:
        raise ValueError("quaternion_xyzw must contain four numbers")
    x, y, z, w = (float(v) for v in values)
    return (w, x, y, z)


class ViserPhoneScene:
    def __init__(self, host: str, port: int) -> None:
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
        self.last_packet_time = 0.0
        self.packet_times: deque[float] = deque()
        self.last_scene_update = 0.0

    def update_from_packet(self, packet: dict[str, Any]) -> None:
        if packet.get("type") != "imu":
            return

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


async def handle_client(
    websocket: WebSocketServerProtocol,
    scene: ViserPhoneScene,
) -> None:
    print(f"WebSocket client connected: {websocket.remote_address}")
    try:
        async for message in websocket:
            if isinstance(message, bytes):
                message = message.decode("utf-8")
            try:
                packet = json.loads(message)
            except json.JSONDecodeError:
                scene.status.value = "bad packet: invalid JSON"
                continue
            scene.update_from_packet(packet)
    finally:
        print(f"WebSocket client disconnected: {websocket.remote_address}")


async def run_async(config: ServerConfig) -> None:
    scene = ViserPhoneScene(config.viser_host, config.viser_port)
    print(f"Viser available on http://127.0.0.1:{config.viser_port}")
    print(
        "WebSocket listening on "
        f"ws://{config.websocket_host}:{config.websocket_port}"
    )

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
    args = parser.parse_args()
    asyncio.run(
        run_async(
            ServerConfig(
                args.websocket_host,
                args.websocket_port,
                args.viser_host,
                args.viser_port,
            )
        )
    )


if __name__ == "__main__":
    main()
