from dataclasses import dataclass, field

from cyclonedds.idl import IdlStruct
from cyclonedds.idl.types import sequence, uint8


@dataclass
class MobileImu(IdlStruct, typename="mobile_zmq.MobileImu"):
    seq: int
    timestamp_msec: int
    quaternion_xyzw: sequence[float] = field(default_factory=list)
    gravity: sequence[float] = field(default_factory=list)
    gyroscope: sequence[float] = field(default_factory=list)
    accelerometer: sequence[float] = field(default_factory=list)


@dataclass
class MobileImageJpeg(IdlStruct, typename="mobile_zmq.MobileImageJpeg"):
    seq: int
    timestamp_msec: int
    width: int
    height: int
    encoding: str
    jpeg: sequence[uint8] = field(default_factory=list)
