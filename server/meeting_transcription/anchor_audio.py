"""Anchor selection and prefix-remapping helpers for transcription chunks."""

from __future__ import annotations

from collections import defaultdict
from dataclasses import dataclass, replace
import re

DEFAULT_FILLER_TEXTS = {
    "嗯",
    "啊",
    "好",
    "对",
}


@dataclass(frozen=True, slots=True)
class Segment:
    text: str
    start_ms: int
    end_ms: int
    speaker_label: str | None = None
    speaker_key: str | None = None

    @property
    def duration_ms(self) -> int:
        return max(0, self.end_ms - self.start_ms)

    def copy_with(self, **changes: object) -> "Segment":
        return replace(self, **changes)


@dataclass(frozen=True, slots=True)
class AnchorRegion:
    speaker_key: str
    start_ms: int
    end_ms: int


@dataclass(frozen=True, slots=True)
class PrefixManifest:
    real_chunk_offset_ms: int
    anchor_regions: tuple[AnchorRegion, ...] = ()
    prefix_total_ms: int | None = None

    def as_dict(self) -> dict[str, object]:
        payload: dict[str, object] = {
            "real_chunk_offset_ms": self.real_chunk_offset_ms,
            "anchor_regions": [
                {
                    "speaker_key": region.speaker_key,
                    "start_ms": region.start_ms,
                    "end_ms": region.end_ms,
                }
                for region in self.anchor_regions
            ],
        }
        if self.prefix_total_ms is not None:
            payload["prefix_total_ms"] = self.prefix_total_ms
        return payload


@dataclass(frozen=True, slots=True)
class PersistedAnchor:
    speaker_key: str
    anchor_order: int
    anchor_text: str
    anchor_duration_ms: int


@dataclass(frozen=True, slots=True)
class PrefixPlan:
    manifest: PrefixManifest
    anchors: tuple[PersistedAnchor, ...] = ()

    def manifest_dict(self) -> dict[str, object]:
        return self.manifest.as_dict()


def select_anchor_candidate(
    segments: list[Segment],
    *,
    chunk_end_ms: int,
    min_duration_ms: int = 1500,
    max_duration_ms: int = 8000,
    chunk_end_margin_ms: int = 2000,
    filler_texts: set[str] | None = None,
) -> Segment | None:
    """Return the first segment that qualifies as a stable speaker anchor."""
    normalized_fillers = filler_texts or DEFAULT_FILLER_TEXTS
    for segment in sorted(segments, key=lambda item: (item.start_ms, item.end_ms)):
        if segment.duration_ms < min_duration_ms or segment.duration_ms > max_duration_ms:
            continue
        if _normalize_text(segment.text) in normalized_fillers:
            continue
        if segment.end_ms > chunk_end_ms - chunk_end_margin_ms:
            continue
        return segment
    return None


def strip_prefix_segments(
    segments: list[Segment],
    manifest: PrefixManifest,
    *,
    guard_band_ms: int = 200,
) -> list[Segment]:
    """Drop prefix-only and boundary-crossing rows, keeping only real-chunk rows."""
    kept: list[Segment] = []
    prefix_boundary = manifest.real_chunk_offset_ms
    for segment in segments:
        if segment.end_ms <= prefix_boundary - guard_band_ms:
            continue
        if segment.start_ms >= prefix_boundary + guard_band_ms:
            kept.append(segment)
            continue
    return kept


def build_speaker_label_map(
    segments: list[Segment],
    manifest: PrefixManifest,
) -> dict[str, str]:
    """Map transient model speaker labels back to persisted speaker keys."""
    label_map: dict[str, str] = {}
    for anchor in manifest.anchor_regions:
        overlaps_by_label: dict[str, int] = defaultdict(int)
        for segment in segments:
            if not segment.speaker_label:
                continue
            overlap_ms = _overlap_ms(
                segment.start_ms,
                segment.end_ms,
                anchor.start_ms,
                anchor.end_ms,
            )
            if overlap_ms <= 0:
                continue
            overlaps_by_label[segment.speaker_label] += overlap_ms
        if not overlaps_by_label:
            continue
        dominant_label = max(
            overlaps_by_label.items(),
            key=lambda item: (item[1], item[0]),
        )[0]
        if dominant_label in label_map:
            continue
        label_map[dominant_label] = anchor.speaker_key
    return label_map


def remap_real_chunk_segments(
    segments: list[Segment],
    label_map: dict[str, str],
    *,
    chunk_start_ms: int,
    real_chunk_offset_ms: int,
) -> list[Segment]:
    """Shift kept real-chunk segments back onto the absolute meeting timeline."""
    remapped: list[Segment] = []
    for segment in segments:
        absolute_start = chunk_start_ms + (segment.start_ms - real_chunk_offset_ms)
        absolute_end = chunk_start_ms + (segment.end_ms - real_chunk_offset_ms)
        remapped.append(
            segment.copy_with(
                start_ms=absolute_start,
                end_ms=absolute_end,
                speaker_key=label_map.get(segment.speaker_label, segment.speaker_key),
            )
        )
    return remapped


def build_prefix_plan(
    anchors: list[PersistedAnchor],
    *,
    inter_anchor_gap_ms: int = 500,
    real_chunk_lead_ms: int = 800,
) -> PrefixPlan | None:
    ordered_anchors = tuple(sorted(anchors, key=lambda anchor: anchor.anchor_order))
    if not ordered_anchors:
        return None

    regions: list[AnchorRegion] = []
    cursor_ms = 0
    for index, anchor in enumerate(ordered_anchors):
        start_ms = cursor_ms
        end_ms = start_ms + anchor.anchor_duration_ms
        regions.append(
            AnchorRegion(
                speaker_key=anchor.speaker_key,
                start_ms=start_ms,
                end_ms=end_ms,
            )
        )
        cursor_ms = end_ms
        if index < len(ordered_anchors) - 1:
            cursor_ms += inter_anchor_gap_ms

    real_chunk_offset_ms = cursor_ms + real_chunk_lead_ms
    manifest = PrefixManifest(
        real_chunk_offset_ms=real_chunk_offset_ms,
        anchor_regions=tuple(regions),
        prefix_total_ms=real_chunk_offset_ms,
    )
    return PrefixPlan(manifest=manifest, anchors=ordered_anchors)


def manifest_from_dict(payload: dict[str, object]) -> PrefixManifest:
    if "real_chunk_offset_ms" not in payload:
        raise ValueError("prefix_manifest missing real_chunk_offset_ms")
    raw_regions = payload.get("anchor_regions", [])
    if not isinstance(raw_regions, list):
        raise ValueError("prefix_manifest anchor_regions must be a list")
    anchor_regions = tuple(_anchor_region_from_payload(region) for region in raw_regions)
    prefix_total_ms = payload.get("prefix_total_ms")
    return PrefixManifest(
        real_chunk_offset_ms=int(payload["real_chunk_offset_ms"]),
        anchor_regions=anchor_regions,
        prefix_total_ms=int(prefix_total_ms) if prefix_total_ms is not None else None,
    )


def segments_from_payload(payload: list[dict[str, object]]) -> list[Segment]:
    if not isinstance(payload, list):
        raise ValueError("segments payload must be a list")
    return [
        Segment(
            text=str(item.get("text", "")),
            start_ms=int(item["start_ms"]),
            end_ms=int(item["end_ms"]),
            speaker_label=(
                str(item["speaker_label"]) if item.get("speaker_label") is not None else None
            ),
            speaker_key=(
                str(item["speaker_key"]) if item.get("speaker_key") is not None else None
            ),
        )
        for item in payload
    ]


def segments_to_payload(segments: list[Segment]) -> list[dict[str, object]]:
    return [
        {
            "text": segment.text,
            "start_ms": segment.start_ms,
            "end_ms": segment.end_ms,
            "speaker_label": segment.speaker_label,
            "speaker_key": segment.speaker_key,
        }
        for segment in segments
    ]


def stable_speaker_key(speaker_label: str | None) -> str | None:
    if not speaker_label:
        return None
    collapsed = re.sub(r"[^a-z0-9]+", "_", speaker_label.strip().lower()).strip("_")
    return collapsed or None


def anchor_from_segment(
    segment: Segment,
    *,
    anchor_order: int,
    fallback_speaker_key: str | None = None,
) -> PersistedAnchor | None:
    speaker_key = segment.speaker_key or fallback_speaker_key or stable_speaker_key(
        segment.speaker_label
    )
    if not speaker_key:
        return None
    return PersistedAnchor(
        speaker_key=speaker_key,
        anchor_order=anchor_order,
        anchor_text=segment.text,
        anchor_duration_ms=segment.duration_ms,
    )


def _normalize_text(text: str) -> str:
    return "".join(text.split()).strip("，。！？,.!?：:；;、")


def _anchor_region_from_payload(region: object) -> AnchorRegion:
    if not isinstance(region, dict):
        raise ValueError("anchor region entries must be objects")
    return AnchorRegion(
        speaker_key=str(region["speaker_key"]),
        start_ms=int(region["start_ms"]),
        end_ms=int(region["end_ms"]),
    )


def _overlap_ms(start_a: int, end_a: int, start_b: int, end_b: int) -> int:
    return max(0, min(end_a, end_b) - max(start_a, start_b))
