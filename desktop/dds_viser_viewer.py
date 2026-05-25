from __future__ import annotations

import argparse
import time
from dataclasses import dataclass

from cyclonedds.domain import DomainParticipant
from cyclonedds.sub import DataReader, Subscriber
from cyclonedds.topic import Topic

from dds_types import MobileImageJpeg, MobileImu
from ws_viser_server import ViserPhoneScene


@dataclass
class DdsViserConfig:
    domain_id: int = 0
    imu_topic: str = "mobile/imu"
    image_topic: str = "mobile/image_jpeg"
    viser_host: str = "0.0.0.0"
    viser_port: int = 8080
    poll_sec: float = 0.002


def _imu_packet(msg: MobileImu) -> dict:
    return {
        "type": "imu",
        "seq": msg.seq,
        "timestamp_msec": msg.timestamp_msec,
        "quaternion_xyzw": list(msg.quaternion_xyzw),
        "gravity": list(msg.gravity),
        "gyroscope": list(msg.gyroscope),
        "accelerometer": list(msg.accelerometer),
    }


def _image_header(msg: MobileImageJpeg) -> dict:
    return {
        "type": "image",
        "seq": msg.seq,
        "timestamp_msec": msg.timestamp_msec,
        "width": msg.width,
        "height": msg.height,
        "encoding": msg.encoding,
    }


def run(config: DdsViserConfig) -> None:
    scene = ViserPhoneScene(config.viser_host, config.viser_port, None)
    participant = DomainParticipant(config.domain_id)
    subscriber = Subscriber(participant)
    imu_reader = DataReader(
        subscriber,
        Topic(participant, config.imu_topic, MobileImu),
    )
    image_reader = DataReader(
        subscriber,
        Topic(participant, config.image_topic, MobileImageJpeg),
    )

    print(f"Viser available on http://127.0.0.1:{config.viser_port}")
    print(
        "CycloneDDS subscribing "
        f"domain={config.domain_id} "
        f"imu_topic={config.imu_topic} "
        f"image_topic={config.image_topic}"
    )

    while True:
        for msg in imu_reader.take(64):
            scene.update_from_packet(_imu_packet(msg))

        for msg in image_reader.take(8):
            jpeg = bytes(msg.jpeg)
            scene.update_from_image(_image_header(msg), jpeg)

        time.sleep(config.poll_sec)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--domain-id", type=int, default=0)
    parser.add_argument("--imu-topic", default="mobile/imu")
    parser.add_argument("--image-topic", default="mobile/image_jpeg")
    parser.add_argument("--viser-host", default="0.0.0.0")
    parser.add_argument("--viser-port", type=int, default=8080)
    parser.add_argument("--poll-sec", type=float, default=0.002)
    args = parser.parse_args()
    run(
        DdsViserConfig(
            domain_id=args.domain_id,
            imu_topic=args.imu_topic,
            image_topic=args.image_topic,
            viser_host=args.viser_host,
            viser_port=args.viser_port,
            poll_sec=args.poll_sec,
        )
    )


if __name__ == "__main__":
    main()
