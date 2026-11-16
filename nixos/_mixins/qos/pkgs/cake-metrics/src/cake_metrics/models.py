from typing import Literal

from pydantic import BaseModel, Field


class Target(BaseModel):
    profile: str
    limit: str
    direction: Literal["ingress", "egress"]
    device: str
    parent: str


class Options(BaseModel):
    bandwidth: int = Field(ge=0)


class Tin(BaseModel):
    avg_delay_us: int
    peak_delay_us: int
    base_delay_us: int
    sparse_flows: int
    bulk_flows: int
    unresponsive_flows: int
    ecn_mark: int


class Qdisc(BaseModel):
    kind: str
    handle: str
    root: bool = False
    parent: str = ""
    options: Options
    bytes: int
    packets: int
    drops: int
    backlog: int
    qlen: int
    tins: list[Tin]


class FlowStats(BaseModel):
    blue_prob: int = Field(ge=0, le=2**32 - 1)
    count: int = Field(ge=0)
    backlog: int = Field(ge=0)
    dropping: bool = False


class Flow(BaseModel):
    parent: str
    handle: str
    stats: FlowStats

    @property
    def tin(self) -> int:
        # CAKE's class minor is one-based, with 1024 flow buckets per tin.
        return (int(self.handle.split(":")[1], 16) - 1) // 1024
