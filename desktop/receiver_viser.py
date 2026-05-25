from __future__ import annotations

import argparse
import json
import time
from dataclasses import dataclass
from typing import Any

import numpy as np
import viser
import zmq


@dataclass
class ReceiverConfig:
    zmq_endpoint: str = "tcp://*:5556"
    viser_host: str = "0.0.0.0"
    viser_port: int = 8080


def xyzw_to_wxyz(values: list[float]) -> tuple[float, float, float, float]:
    if len(values) != 4:
        raise ValueError("quaternion_xyzw must contain four numbers")
    x, y, z, w = (float(v) for v in values)
    return (w, x, y, z)


def decode_message(parts: list[bytes]) -> dict[str, Any] | None:
    if not parts:
        return None
    raw = parts[-1].decode("utf-8")
    if raw.startswith("{"):
        return json.loads(raw)
    pieces = raw.split(" ", 1)
    if len(pieces) == 2 and pieces[1].startswith("{"):
        return json.loads(pieces[1])
    return None


def run(config: ReceiverConfig) -> None:
    server = viser.ViserServer(host=config.viser_host, port=config.viser_port)
    server.scene.world_axes.visible = True
    server.scene.add_grid("/floor", width=2.0, height=2.0)
    phone_frame = server.scene.add_frame(
        "/phone",
        axes_length=0.25,
        axes_radius=0.01,
        position=(0.0, 0.0, 0.25),
    )
    server.scene.add_box(
        "/phone/body",
        dimensions=(0.08, 0.16, 0.015),
        color=(45, 194, 165),
        position=(0.0, 0.0, 0.25),
    )
    status = server.gui.add_text("Last packet", initial_value="none")

    context = zmq.Context.instance()
    socket = context.socket(zmq.SUB)
    socket.bind(config.zmq_endpoint)
    socket.setsockopt_string(zmq.SUBSCRIBE, "")

    print(f"ZMQ SUB listening on {config.zmq_endpoint}")
    print(f"Viser available on http://127.0.0.1:{config.viser_port}")

    last_packet_time = 0.0
    while True:
        try:
            parts = socket.recv_multipart(flags=zmq.NOBLOCK)
        except zmq.Again:
            time.sleep(0.002)
            continue

        packet = decode_message(parts)
        if not packet or packet.get("type") != "imu":
            continue

        try:
            phone_frame.wxyz = xyzw_to_wxyz(packet["quaternion_xyzw"])
        except (KeyError, TypeError, ValueError) as exc:
            status.value = f"bad packet: {exc}"
            continue

        now = time.time()
        hz = 1.0 / (now - last_packet_time) if last_packet_time else 0.0
        last_packet_time = now
        gravity = np.asarray(packet.get("gravity", [0.0, 0.0, 0.0]), dtype=float)
        status.value = (
            f"seq={packet.get('seq', '?')}  "
            f"rate={hz:0.1f} Hz  "
            f"gravity={np.round(gravity, 3).tolist()}"
        )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--zmq-endpoint", default="tcp://*:5556")
    parser.add_argument("--viser-host", default="0.0.0.0")
    parser.add_argument("--viser-port", type=int, default=8080)
    args = parser.parse_args()
    run(ReceiverConfig(args.zmq_endpoint, args.viser_host, args.viser_port))


if __name__ == "__main__":
    main()
