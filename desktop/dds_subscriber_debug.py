from __future__ import annotations

import argparse
import time
from collections import deque

from cyclonedds.domain import DomainParticipant
from cyclonedds.sub import DataReader, Subscriber
from cyclonedds.topic import Topic

from dds_types import MobileImageJpeg, MobileImu


def _record(samples: deque[float]) -> None:
    now = time.time()
    samples.append(now)
    while samples and now - samples[0] > 1.0:
        samples.popleft()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--domain-id", type=int, default=0)
    parser.add_argument("--imu-topic", default="mobile/imu")
    parser.add_argument("--image-topic", default="mobile/image_jpeg")
    parser.add_argument("--poll-sec", type=float, default=0.01)
    args = parser.parse_args()

    participant = DomainParticipant(args.domain_id)
    subscriber = Subscriber(participant)
    imu_reader = DataReader(
        subscriber,
        Topic(participant, args.imu_topic, MobileImu),
    )
    image_reader = DataReader(
        subscriber,
        Topic(participant, args.image_topic, MobileImageJpeg),
    )

    imu_times: deque[float] = deque()
    image_times: deque[float] = deque()
    last_print = 0.0
    last_imu_seq = None
    last_image_seq = None
    last_jpeg_size = 0

    print(
        "CycloneDDS subscribing "
        f"domain={args.domain_id} "
        f"imu_topic={args.imu_topic} "
        f"image_topic={args.image_topic}"
    )

    while True:
        for msg in imu_reader.take(64):
            _record(imu_times)
            last_imu_seq = msg.seq

        for msg in image_reader.take(8):
            _record(image_times)
            last_image_seq = msg.seq
            last_jpeg_size = len(msg.jpeg)

        now = time.time()
        if now - last_print >= 1.0:
            last_print = now
            print(
                "DDS receive "
                f"imu={len(imu_times):.1f}Hz seq={last_imu_seq} "
                f"image={len(image_times):.1f}Hz seq={last_image_seq} "
                f"last_jpeg={last_jpeg_size}B"
            )
        time.sleep(args.poll_sec)


if __name__ == "__main__":
    main()
