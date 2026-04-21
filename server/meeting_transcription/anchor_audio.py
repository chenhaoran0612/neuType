"""Anchor selection and prefix-remapping helpers for transcription chunks."""

from __future__ import annotations

from collections import defaultdict
from dataclasses import dataclass, replace

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
                speaker_key=label_map.get(segment.speaker_label),
            )
        )
    return remapped



def manifest_from_dict(payload: dict[str, object]) -> PrefixManifest:
    anchor_regions = tuple(
        AnchorRegion(
            speaker_key=str(region["speaker_key"]),
            start_ms=int(region["start_ms"]),
            end_ms=int(region["end_ms"]),
        )
        for region in payload.get("anchor_regions", [])
    )
    prefix_total_ms = payload.get("prefix_total_ms")
    return PrefixManifest(
        real_chunk_offset_ms=int(payload["real_chunk_offset_ms"]),
        anchor_regions=anchor_regions,
        prefix_total_ms=int(prefix_total_ms) if prefix_total_ms is not None else None,
    )



def segments_from_payload(payload: list[dict[str, object]]) -> list[Segment]:
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



def _normalize_text(text: str) -> str:
    return "".join(text.split()).strip("，。！？,.!?：:；;、")



def _overlap_ms(start_a: int, end_a: int, start_b: int, end_b: int) -> int:
    return max(0, min(end_a, end_b) - max(start_a, start_b))
