from meeting_transcription.anchor_audio import (
    AnchorRegion,
    PrefixManifest,
    Segment,
    build_speaker_label_map,
    remap_real_chunk_segments,
    select_anchor_candidate,
    strip_prefix_segments,
)


def test_select_first_qualified_anchor_skips_short_filler_segment():
    segments = [
        Segment(text="嗯", start_ms=0, end_ms=300, speaker_label="Speaker 1"),
        Segment(text="我们开始今天的周会", start_ms=500, end_ms=3600, speaker_label="Speaker 1"),
    ]

    anchor = select_anchor_candidate(segments, chunk_end_ms=300000)

    assert anchor is not None
    assert anchor.text == "我们开始今天的周会"



def test_select_anchor_candidate_skips_boundary_adjacent_segment():
    segments = [
        Segment(
            text="最后一句太靠近边界",
            start_ms=296500,
            end_ms=298500,
            speaker_label="Speaker 1",
        ),
        Segment(
            text="我们开始今天的周会",
            start_ms=1000,
            end_ms=3500,
            speaker_label="Speaker 1",
        ),
    ]

    anchor = select_anchor_candidate(segments, chunk_end_ms=300000)

    assert anchor is not None
    assert anchor.text == "我们开始今天的周会"



def test_strip_prefix_segments_discards_boundary_crossing_rows():
    manifest = PrefixManifest(real_chunk_offset_ms=4000)
    segments = [
        Segment(text="anchor", start_ms=0, end_ms=1000, speaker_label="Speaker 1"),
        Segment(text="crossing", start_ms=3900, end_ms=4200, speaker_label="Speaker 1"),
        Segment(text="real", start_ms=4300, end_ms=5000, speaker_label="Speaker 2"),
    ]

    kept = strip_prefix_segments(segments, manifest, guard_band_ms=200)

    assert [segment.text for segment in kept] == ["real"]



def test_build_label_map_and_remap_real_chunk_segments():
    manifest = PrefixManifest(
        real_chunk_offset_ms=4000,
        anchor_regions=(
            AnchorRegion(speaker_key="speaker_a", start_ms=0, end_ms=1000),
            AnchorRegion(speaker_key="speaker_b", start_ms=1500, end_ms=2500),
        ),
    )
    segments = [
        Segment(text="anchor a", start_ms=0, end_ms=950, speaker_label="Speaker 7"),
        Segment(text="anchor b", start_ms=1500, end_ms=2450, speaker_label="Speaker 2"),
        Segment(text="real 1", start_ms=4300, end_ms=5000, speaker_label="Speaker 2"),
        Segment(text="real 2", start_ms=5100, end_ms=5800, speaker_label="Speaker 7"),
    ]

    label_map = build_speaker_label_map(segments, manifest)
    kept = strip_prefix_segments(segments, manifest, guard_band_ms=200)
    remapped = remap_real_chunk_segments(
        kept,
        label_map,
        chunk_start_ms=300000,
        real_chunk_offset_ms=manifest.real_chunk_offset_ms,
    )

    assert label_map == {"Speaker 7": "speaker_a", "Speaker 2": "speaker_b"}
    assert [
        (segment.text, segment.start_ms, segment.end_ms, segment.speaker_key)
        for segment in remapped
    ] == [
        ("real 1", 300300, 301000, "speaker_b"),
        ("real 2", 301100, 301800, "speaker_a"),
    ]



def test_build_label_map_ignores_later_anchor_collision_for_same_transient_label():
    manifest = PrefixManifest(
        real_chunk_offset_ms=3000,
        anchor_regions=(
            AnchorRegion(speaker_key="speaker_a", start_ms=0, end_ms=1000),
            AnchorRegion(speaker_key="speaker_b", start_ms=1200, end_ms=2200),
        ),
    )
    segments = [
        Segment(text="a", start_ms=0, end_ms=900, speaker_label="Speaker 2"),
        Segment(text="b", start_ms=1200, end_ms=2100, speaker_label="Speaker 2"),
    ]

    label_map = build_speaker_label_map(segments, manifest)

    assert label_map == {"Speaker 2": "speaker_a"}



def test_remap_real_chunk_segments_preserves_existing_speaker_key_when_unmapped():
    remapped = remap_real_chunk_segments(
        [
            Segment(
                text="real",
                start_ms=4300,
                end_ms=5000,
                speaker_label="Speaker 9",
                speaker_key="speaker_existing",
            )
        ],
        {},
        chunk_start_ms=300000,
        real_chunk_offset_ms=4000,
    )

    assert [(segment.start_ms, segment.end_ms, segment.speaker_key) for segment in remapped] == [
        (300300, 301000, "speaker_existing")
    ]
