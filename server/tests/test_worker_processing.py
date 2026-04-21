from __future__ import annotations

from datetime import timedelta
import hashlib
import json
from pathlib import Path
import wave

import pytest

from meeting_transcription.db import create_engine, create_session_factory
from meeting_transcription.models import Base, SessionChunk, SpeakerAnchor, TranscriptionSession, utcnow
from meeting_transcription.storage import LocalArtifactStorage
from meeting_transcription.worker import run_pending_chunk_once


class StubTranscriber:
    def transcribe_chunk(self, *, session: TranscriptionSession, chunk: SessionChunk, audio_path: str, prefix_plan=None):
        del audio_path, prefix_plan
        return {
            "text": f"chunk-{chunk.chunk_index}",
            "segment_count": 1,
            "source_type": chunk.source_type,
            "session_id": session.session_id,
        }


class FailingOnceTranscriber:
    def __init__(self) -> None:
        self.calls = 0

    def transcribe_chunk(self, *, session: TranscriptionSession, chunk: SessionChunk, audio_path: str, prefix_plan=None):
        del prefix_plan
        self.calls += 1
        if self.calls == 1:
            raise RuntimeError("temporary model outage")
        return StubTranscriber().transcribe_chunk(
            session=session, chunk=chunk, audio_path=audio_path
        )


class AlwaysFailingTranscriber:
    def transcribe_chunk(
        self, *, session: TranscriptionSession, chunk: SessionChunk, audio_path: str, prefix_plan=None
    ):
        del session, chunk, audio_path, prefix_plan
        raise RuntimeError("persistent model outage")


class WorkerHarness:
    def __init__(self, tmp_path: Path) -> None:
        self.storage = LocalArtifactStorage(tmp_path / "artifacts")
        self.engine = create_engine(f"sqlite+pysqlite:///{tmp_path / 'worker.db'}")
        Base.metadata.create_all(self.engine)
        self.session_factory = create_session_factory(self.engine)
        self.transcriber = StubTranscriber()

    def close(self) -> None:
        self.engine.dispose()

    def seed_session_with_chunks(self, indexes: list[int]) -> TranscriptionSession:
        db = self.session_factory()
        try:
            session = TranscriptionSession(
                session_id="mts_worker",
                client_session_token="worker-token",
                status="receiving_chunks",
                input_mode="live_chunks",
                chunk_duration_ms=300000,
                chunk_overlap_ms=2500,
            )
            db.add(session)
            db.flush()

            for index in indexes:
                payload = self._wav_bytes(f"live-{index}".encode())
                storage_path = self.storage.session_path(
                    session.session_id, "live-chunks", f"{index}.wav"
                )
                self.storage.write_bytes(storage_path, payload)
                db.add(
                    SessionChunk(
                        session_id=session.id,
                        chunk_index=index,
                        source_type="live_chunk",
                        start_ms=index * 300000,
                        end_ms=(index + 1) * 300000,
                        duration_ms=300000,
                        sha256=hashlib.sha256(payload).hexdigest(),
                        storage_path=storage_path,
                        upload_status="uploaded",
                        process_status="pending",
                    )
                )

            db.commit()
            db.refresh(session)
            return session
        finally:
            db.close()

    def seed_processed_result(self, public_session: TranscriptionSession, *, chunk_index: int) -> None:
        db = self.session_factory()
        try:
            chunk = self._fetch_chunk(db, public_session.session_id, chunk_index, "live_chunk")
            chunk.process_status = "processed"
            chunk.result_segment_count = 1
            db.commit()
        finally:
            db.close()

    def seed_processed_normalized_result(
        self,
        public_session: TranscriptionSession,
        *,
        chunk_index: int,
        normalized_segments: list[dict[str, object]],
    ) -> None:
        db = self.session_factory()
        try:
            chunk = self._fetch_chunk(db, public_session.session_id, chunk_index, "live_chunk")
            chunk.process_status = "processed"
            chunk.result_segment_count = len(normalized_segments)
            chunk.normalized_segments_json = json.dumps(normalized_segments)
            db.commit()
        finally:
            db.close()

    def seed_session_with_missing_live_chunks(self) -> TranscriptionSession:
        db = self.session_factory()
        try:
            session = TranscriptionSession(
                session_id="mts_fallback",
                client_session_token="fallback-token",
                status="receiving_chunks",
                input_mode="live_chunks",
                chunk_duration_ms=300000,
                chunk_overlap_ms=2500,
            )
            db.add(session)
            db.flush()

            payload = self._wav_bytes(b"live-0")
            storage_path = self.storage.session_path(session.session_id, "live-chunks", "0.wav")
            self.storage.write_bytes(storage_path, payload)
            db.add(
                SessionChunk(
                    session_id=session.id,
                    chunk_index=0,
                    source_type="live_chunk",
                    start_ms=0,
                    end_ms=300000,
                    duration_ms=300000,
                    sha256=hashlib.sha256(payload).hexdigest(),
                    storage_path=storage_path,
                    upload_status="uploaded",
                    process_status="pending",
                )
            )
            db.commit()
            db.refresh(session)
            return session
        finally:
            db.close()

    def attach_full_audio(self, public_session: TranscriptionSession, audio_path: Path) -> None:
        db = self.session_factory()
        try:
            session = self.fetch_session(public_session.session_id, db=db)
            storage_path = self.storage.session_path(session.session_id, "full-audio", "recording.wav")
            self.storage.write_bytes(storage_path, audio_path.read_bytes())
            session.final_audio_uploaded = True
            session.final_audio_sha256 = hashlib.sha256(audio_path.read_bytes()).hexdigest()
            session.final_audio_storage_path = storage_path
            db.commit()
        finally:
            db.close()

    def mark_full_audio_uploaded_without_path(self, public_session: TranscriptionSession) -> None:
        db = self.session_factory()
        try:
            session = self.fetch_session(public_session.session_id, db=db)
            session.final_audio_uploaded = True
            session.final_audio_sha256 = "sha-without-storage-path"
            session.final_audio_storage_path = None
            db.commit()
        finally:
            db.close()

    def finalize(self, public_session_id: str, *, expected_chunk_count: int = 3) -> None:
        from meeting_transcription.repositories import finalize_session
        from meeting_transcription.schemas import FinalizeSessionRequest

        db = self.session_factory()
        try:
            finalize_session(
                db,
                public_session_id,
                FinalizeSessionRequest(
                    expected_chunk_count=expected_chunk_count,
                    preferred_input_mode="full_audio_fallback",
                    allow_full_audio_fallback=True,
                ),
            )
        finally:
            db.close()

    def finalize_without_expected_count(self, public_session_id: str) -> None:
        from meeting_transcription.repositories import finalize_session
        from meeting_transcription.schemas import FinalizeSessionRequest

        db = self.session_factory()
        try:
            finalize_session(
                db,
                public_session_id,
                FinalizeSessionRequest(
                    expected_chunk_count=None,
                    preferred_input_mode="live_chunks",
                    allow_full_audio_fallback=True,
                ),
            )
        finally:
            db.close()

    def run_once(self, transcriber=None) -> bool:
        db = self.session_factory()
        try:
            return run_pending_chunk_once(
                db, transcriber or self.transcriber, storage=self.storage
            )
        finally:
            db.close()

    def run_until_idle(self, max_iterations: int = 20) -> None:
        for _ in range(max_iterations):
            if not self.run_once():
                return
        raise AssertionError("worker did not become idle")

    def fetch_session(self, public_session_id: str, *, db=None) -> TranscriptionSession:
        owns_session = db is None
        if db is None:
            db = self.session_factory()
        try:
            session = db.query(TranscriptionSession).filter_by(session_id=public_session_id).one()
            db.refresh(session)
            return session
        finally:
            if owns_session:
                db.close()

    def fetch_chunk(self, public_session_id: str, chunk_index: int, source_type: str) -> SessionChunk:
        db = self.session_factory()
        try:
            chunk = self._fetch_chunk(db, public_session_id, chunk_index, source_type)
            db.refresh(chunk)
            return chunk
        finally:
            db.close()

    def list_chunks(self, public_session_id: str, source_type: str) -> list[SessionChunk]:
        db = self.session_factory()
        try:
            session = self.fetch_session(public_session_id, db=db)
            chunks = (
                db.query(SessionChunk)
                .filter_by(session_id=session.id, source_type=source_type)
                .order_by(SessionChunk.chunk_index)
                .all()
            )
            for chunk in chunks:
                db.refresh(chunk)
            return chunks
        finally:
            db.close()

    def list_speaker_anchors(self, public_session_id: str) -> list[SpeakerAnchor]:
        db = self.session_factory()
        try:
            session = self.fetch_session(public_session_id, db=db)
            anchors = (
                db.query(SpeakerAnchor)
                .filter_by(session_id=session.id)
                .order_by(SpeakerAnchor.anchor_order)
                .all()
            )
            for anchor in anchors:
                db.refresh(anchor)
            return anchors
        finally:
            db.close()

    def mark_chunk_processing_state(
        self,
        public_session_id: str,
        chunk_index: int,
        *,
        source_type: str = "live_chunk",
        started_at_offset_seconds: int = 0,
    ) -> None:
        db = self.session_factory()
        try:
            chunk = self._fetch_chunk(db, public_session_id, chunk_index, source_type)
            chunk.process_status = "processing"
            chunk.processing_started_at = utcnow() - timedelta(
                seconds=started_at_offset_seconds
            )
            chunk.processing_completed_at = None
            db.commit()
        finally:
            db.close()

    def set_chunk_retry_count(
        self,
        public_session_id: str,
        chunk_index: int,
        retry_count: int,
        *,
        source_type: str = "live_chunk",
    ) -> None:
        db = self.session_factory()
        try:
            chunk = self._fetch_chunk(db, public_session_id, chunk_index, source_type)
            chunk.retry_count = retry_count
            db.commit()
        finally:
            db.close()

    @staticmethod
    def _wav_bytes(tag: bytes) -> bytes:
        return b"RIFFtestWAVEfmt " + tag + (b"\x00" * 64)

    @staticmethod
    def _fetch_chunk(db, public_session_id: str, chunk_index: int, source_type: str) -> SessionChunk:
        session = db.query(TranscriptionSession).filter_by(session_id=public_session_id).one()
        return (
            db.query(SessionChunk)
            .filter_by(session_id=session.id, chunk_index=chunk_index, source_type=source_type)
            .one()
        )


@pytest.fixture
def worker_harness(tmp_path):
    harness = WorkerHarness(tmp_path)
    try:
        yield harness
    finally:
        harness.close()


@pytest.fixture
def full_audio_file(tmp_path: Path) -> Path:
    audio_path = tmp_path / "full_audio.wav"
    sample_rate = 1000
    duration_ms = 620000
    frame_count = sample_rate * duration_ms // 1000

    with wave.open(str(audio_path), "wb") as wav_file:
        wav_file.setnchannels(1)
        wav_file.setsampwidth(2)
        wav_file.setframerate(sample_rate)
        wav_file.writeframes(b"\x00\x00" * frame_count)

    return audio_path


@pytest.fixture
def zero_duration_full_audio_file(tmp_path: Path) -> Path:
    audio_path = tmp_path / "zero_duration_full_audio.wav"
    with wave.open(str(audio_path), "wb") as wav_file:
        wav_file.setnchannels(1)
        wav_file.setsampwidth(2)
        wav_file.setframerate(1000)
        wav_file.writeframes(b"")
    return audio_path


@pytest.fixture
def invalid_full_audio_file(tmp_path: Path) -> Path:
    audio_path = tmp_path / "invalid_full_audio.wav"
    audio_path.write_bytes(b"not-a-wav")
    return audio_path


def test_worker_creates_anchor_then_uses_prefix_plan_and_persists_normalized_segments(
    worker_harness: WorkerHarness,
):
    class PrefixAwareTranscriber:
        def __init__(self) -> None:
            self.prefix_plans = []

        def transcribe_chunk(
            self,
            *,
            session: TranscriptionSession,
            chunk: SessionChunk,
            audio_path: str,
            prefix_plan=None,
        ):
            del session, audio_path
            self.prefix_plans.append(prefix_plan)
            if chunk.chunk_index == 0:
                return {
                    "segment_count": 2,
                    "segments": [
                        {"text": "嗯", "start_ms": 0, "end_ms": 300, "speaker_label": "Speaker 1"},
                        {
                            "text": "我们开始今天的周会",
                            "start_ms": 500,
                            "end_ms": 3600,
                            "speaker_label": "Speaker 1",
                        },
                    ],
                }
            assert prefix_plan is not None
            return {
                "segment_count": 99,
                "segments": [
                    {
                        "text": "anchor revisit",
                        "start_ms": 0,
                        "end_ms": 3000,
                        "speaker_label": "Speaker 9",
                    },
                    {
                        "text": "real",
                        "start_ms": prefix_plan.manifest.real_chunk_offset_ms + 300,
                        "end_ms": prefix_plan.manifest.real_chunk_offset_ms + 1100,
                        "speaker_label": "Speaker 9",
                    },
                ],
            }

    session = worker_harness.seed_session_with_chunks(indexes=[0, 1])
    transcriber = PrefixAwareTranscriber()

    assert worker_harness.run_once(transcriber=transcriber) is True
    assert worker_harness.list_speaker_anchors(session.session_id) == []

    assert worker_harness.run_once(transcriber=transcriber) is True
    anchors = worker_harness.list_speaker_anchors(session.session_id)
    assert [(anchor.speaker_key, anchor.anchor_text) for anchor in anchors] == [
        ("speaker_1", "我们开始今天的周会")
    ]

    assert worker_harness.run_once(transcriber=transcriber) is True

    second_chunk = worker_harness.fetch_chunk(session.session_id, 1, "live_chunk")
    normalized_segments = json.loads(second_chunk.normalized_segments_json)
    prepared_manifest = json.loads(second_chunk.prepared_prefix_manifest_json)

    assert transcriber.prefix_plans[0] is None
    assert transcriber.prefix_plans[1] is not None
    assert prepared_manifest["real_chunk_offset_ms"] == transcriber.prefix_plans[1].manifest.real_chunk_offset_ms
    assert normalized_segments == [
        {
            "text": "real",
            "start_ms": 300300,
            "end_ms": 301100,
            "speaker_label": "Speaker 9",
            "speaker_key": "speaker_1",
        }
    ]
    assert second_chunk.result_segment_count == 1



def test_worker_resets_chunk_when_prefix_metadata_is_malformed(worker_harness: WorkerHarness):
    class MalformedPrefixTranscriber:
        def transcribe_chunk(
            self,
            *,
            session: TranscriptionSession,
            chunk: SessionChunk,
            audio_path: str,
            prefix_plan=None,
        ):
            del session, chunk, audio_path, prefix_plan
            return {
                "segment_count": 1,
                "prefix_manifest": {"real_chunk_offset_ms": "not-an-int"},
                "segments": [
                    {"text": "broken", "start_ms": 4200, "end_ms": 5000, "speaker_label": "Speaker 1"}
                ],
            }

    session = worker_harness.seed_session_with_chunks(indexes=[0])

    assert worker_harness.run_once(transcriber=MalformedPrefixTranscriber()) is True

    chunk = worker_harness.fetch_chunk(session.session_id, 0, "live_chunk")
    assert chunk.process_status == "pending"
    assert chunk.retry_count == 1
    assert "not-an-int" in chunk.error_message
    assert chunk.normalized_segments_json is None


def test_out_of_order_processed_chunk_does_not_create_anchor_before_frontier_advances(
    worker_harness: WorkerHarness,
):
    class ChunkZeroTranscriber:
        def transcribe_chunk(
            self,
            *,
            session: TranscriptionSession,
            chunk: SessionChunk,
            audio_path: str,
            prefix_plan=None,
        ):
            del session, audio_path, prefix_plan
            assert chunk.chunk_index == 0
            return {
                "segment_count": 1,
                "segments": [
                    {
                        "text": "我们开始今天的周会",
                        "start_ms": 500,
                        "end_ms": 3600,
                        "speaker_label": "Speaker 1",
                    }
                ],
            }

    session = worker_harness.seed_session_with_chunks(indexes=[0, 1])
    worker_harness.seed_processed_normalized_result(
        session,
        chunk_index=1,
        normalized_segments=[
            {
                "text": "第二位说话人的有效锚点",
                "start_ms": 300500,
                "end_ms": 303500,
                "speaker_label": "Speaker 2",
                "speaker_key": "speaker_2",
            }
        ],
    )

    assert worker_harness.run_once(transcriber=ChunkZeroTranscriber()) is True
    assert worker_harness.list_speaker_anchors(session.session_id) == []

    assert worker_harness.run_once(transcriber=ChunkZeroTranscriber()) is True

    anchors = worker_harness.list_speaker_anchors(session.session_id)
    refreshed = worker_harness.fetch_session(session.session_id)
    assert refreshed.last_committed_chunk_index == 1
    assert [(anchor.speaker_key, anchor.anchor_text) for anchor in anchors] == [
        ("speaker_1", "我们开始今天的周会"),
        ("speaker_2", "第二位说话人的有效锚点"),
    ]


def test_worker_remaps_no_prefix_chunk_segments_to_absolute_timeline(
    worker_harness: WorkerHarness,
):
    class LocalTimestampTranscriber:
        def transcribe_chunk(
            self,
            *,
            session: TranscriptionSession,
            chunk: SessionChunk,
            audio_path: str,
            prefix_plan=None,
        ):
            del session, audio_path, prefix_plan
            assert chunk.chunk_index == 1
            return {
                "segment_count": 1,
                "segments": [
                    {
                        "text": "local time",
                        "start_ms": 100,
                        "end_ms": 1600,
                        "speaker_label": "Speaker 3",
                    }
                ],
            }

    session = worker_harness.seed_session_with_chunks(indexes=[1])

    assert worker_harness.run_once(transcriber=LocalTimestampTranscriber()) is True

    chunk = worker_harness.fetch_chunk(session.session_id, 1, "live_chunk")
    assert json.loads(chunk.normalized_segments_json) == [
        {
            "text": "local time",
            "start_ms": 300100,
            "end_ms": 301600,
            "speaker_label": "Speaker 3",
            "speaker_key": None,
        }
    ]


def test_worker_only_commits_next_chunk_in_order(worker_harness: WorkerHarness):
    session = worker_harness.seed_session_with_chunks(indexes=[0, 1])
    worker_harness.seed_processed_result(session, chunk_index=1)

    worker_harness.run_once()

    refreshed = worker_harness.fetch_session(session.session_id)
    first_chunk = worker_harness.fetch_chunk(session.session_id, 0, "live_chunk")
    second_chunk = worker_harness.fetch_chunk(session.session_id, 1, "live_chunk")
    assert refreshed.last_committed_chunk_index == -1
    assert first_chunk.process_status == "processed"
    assert second_chunk.process_status == "processed"


def test_finalize_uses_fallback_split_when_live_chunks_missing(
    worker_harness: WorkerHarness, full_audio_file: Path
):
    session = worker_harness.seed_session_with_missing_live_chunks()
    worker_harness.attach_full_audio(session, full_audio_file)

    worker_harness.finalize(session.session_id)
    worker_harness.run_until_idle()

    refreshed = worker_harness.fetch_session(session.session_id)
    live_chunk = worker_harness.fetch_chunk(session.session_id, 0, "live_chunk")
    fallback_chunks = worker_harness.list_chunks(
        session.session_id, "server_split_from_full_audio"
    )

    assert refreshed.selected_final_input_mode == "full_audio_fallback"
    assert refreshed.input_mode == "full_audio_fallback"
    assert refreshed.status == "completed"
    assert refreshed.last_committed_chunk_index == len(fallback_chunks) - 1
    assert live_chunk.process_status == "pending"
    assert [chunk.chunk_index for chunk in fallback_chunks] == [0, 1, 2]
    assert all(chunk.process_status == "completed" for chunk in fallback_chunks)


def test_fallback_after_live_commit_resets_frontier_and_completes_from_fallback(
    worker_harness: WorkerHarness, full_audio_file: Path
):
    session = worker_harness.seed_session_with_missing_live_chunks()
    assert worker_harness.run_once() is True
    assert worker_harness.run_once() is True

    committed_live_session = worker_harness.fetch_session(session.session_id)
    committed_live_chunk = worker_harness.fetch_chunk(session.session_id, 0, "live_chunk")
    assert committed_live_session.last_committed_chunk_index == 0
    assert committed_live_chunk.process_status == "completed"

    worker_harness.attach_full_audio(session, full_audio_file)
    worker_harness.finalize(session.session_id)
    worker_harness.run_until_idle()

    refreshed = worker_harness.fetch_session(session.session_id)
    fallback_chunks = worker_harness.list_chunks(
        session.session_id, "server_split_from_full_audio"
    )
    live_chunk = worker_harness.fetch_chunk(session.session_id, 0, "live_chunk")

    assert refreshed.selected_final_input_mode == "full_audio_fallback"
    assert refreshed.last_committed_chunk_index == len(fallback_chunks) - 1
    assert refreshed.status == "completed"
    assert [chunk.chunk_index for chunk in fallback_chunks] == [0, 1, 2]
    assert all(chunk.process_status == "completed" for chunk in fallback_chunks)
    assert live_chunk.process_status == "completed"


def test_worker_does_not_complete_live_session_before_finalize(
    worker_harness: WorkerHarness,
):
    session = worker_harness.seed_session_with_chunks(indexes=[0])

    assert worker_harness.run_once() is True
    assert worker_harness.run_once() is True

    refreshed = worker_harness.fetch_session(session.session_id)
    chunk = worker_harness.fetch_chunk(session.session_id, 0, "live_chunk")
    assert refreshed.status == "receiving_chunks"
    assert refreshed.last_committed_chunk_index == 0
    assert chunk.process_status == "completed"


def test_finalize_does_not_select_fallback_without_full_audio_storage_path(
    worker_harness: WorkerHarness,
):
    session = worker_harness.seed_session_with_missing_live_chunks()
    worker_harness.mark_full_audio_uploaded_without_path(session)

    worker_harness.finalize(session.session_id)
    worker_harness.run_until_idle()

    refreshed = worker_harness.fetch_session(session.session_id)
    fallback_chunks = worker_harness.list_chunks(
        session.session_id, "server_split_from_full_audio"
    )
    assert refreshed.status == "awaiting_fallback"
    assert refreshed.selected_final_input_mode == "live_chunks"
    assert refreshed.input_mode == "live_chunks"
    assert fallback_chunks == []


def test_transcriber_failure_resets_chunk_to_pending_for_retry(
    worker_harness: WorkerHarness,
):
    session = worker_harness.seed_session_with_chunks(indexes=[0])
    transcriber = FailingOnceTranscriber()

    assert worker_harness.run_once(transcriber=transcriber) is True
    failed_chunk = worker_harness.fetch_chunk(session.session_id, 0, "live_chunk")
    assert failed_chunk.process_status == "pending"
    assert failed_chunk.retry_count == 1
    assert "temporary model outage" in failed_chunk.error_message

    assert worker_harness.run_once(transcriber=transcriber) is True
    assert worker_harness.run_once(transcriber=transcriber) is True

    retried_chunk = worker_harness.fetch_chunk(session.session_id, 0, "live_chunk")
    refreshed = worker_harness.fetch_session(session.session_id)
    assert retried_chunk.process_status == "completed"
    assert retried_chunk.retry_count == 1
    assert refreshed.status == "receiving_chunks"


def test_splitter_rejects_invalid_overlap_config(
    full_audio_file: Path,
):
    from meeting_transcription.audio_chunks import split_full_audio_into_chunks

    with pytest.raises(ValueError, match="overlap_ms"):
        split_full_audio_into_chunks(str(full_audio_file), 300000, 300000)

    with pytest.raises(ValueError, match="overlap_ms"):
        split_full_audio_into_chunks(str(full_audio_file), 300000, -1)


def test_repeat_finalize_does_not_rewind_existing_fallback_progress(
    worker_harness: WorkerHarness, full_audio_file: Path
):
    session = worker_harness.seed_session_with_missing_live_chunks()
    worker_harness.attach_full_audio(session, full_audio_file)

    worker_harness.finalize(session.session_id)
    assert worker_harness.run_once() is True  # split fallback chunks
    assert worker_harness.run_once() is True  # process fallback chunk 0
    assert worker_harness.run_once() is True  # commit fallback chunk 0

    progressed = worker_harness.fetch_session(session.session_id)
    assert progressed.last_committed_chunk_index == 0

    worker_harness.finalize(session.session_id)
    worker_harness.run_until_idle()

    refreshed = worker_harness.fetch_session(session.session_id)
    fallback_chunks = worker_harness.list_chunks(
        session.session_id, "server_split_from_full_audio"
    )
    assert refreshed.status == "completed"
    assert refreshed.last_committed_chunk_index == len(fallback_chunks) - 1
    assert all(chunk.process_status == "completed" for chunk in fallback_chunks)


def test_finalize_without_expected_count_stays_non_terminal(
    worker_harness: WorkerHarness,
):
    session = worker_harness.seed_session_with_chunks(indexes=[0])

    worker_harness.finalize_without_expected_count(session.session_id)
    worker_harness.run_until_idle()

    refreshed = worker_harness.fetch_session(session.session_id)
    assert refreshed.status == "awaiting_finalize"
    assert refreshed.selected_final_input_mode == "live_chunks"


def test_retry_exhaustion_marks_session_failed_without_fallback(
    worker_harness: WorkerHarness,
):
    session = worker_harness.seed_session_with_chunks(indexes=[0])
    transcriber = AlwaysFailingTranscriber()

    for _ in range(3):
        assert worker_harness.run_once(transcriber=transcriber) is True

    refreshed = worker_harness.fetch_session(session.session_id)
    chunk = worker_harness.fetch_chunk(session.session_id, 0, "live_chunk")
    assert refreshed.status == "failed"
    assert refreshed.last_error == "persistent model outage"
    assert chunk.process_status == "failed"
    assert chunk.retry_count == 3


def test_retry_exhaustion_moves_live_session_to_awaiting_fallback_when_available(
    worker_harness: WorkerHarness, full_audio_file: Path
):
    session = worker_harness.seed_session_with_chunks(indexes=[0])
    worker_harness.attach_full_audio(session, full_audio_file)
    worker_harness.finalize(session.session_id, expected_chunk_count=1)
    transcriber = AlwaysFailingTranscriber()

    for _ in range(3):
        assert worker_harness.run_once(transcriber=transcriber) is True

    refreshed = worker_harness.fetch_session(session.session_id)
    chunk = worker_harness.fetch_chunk(session.session_id, 0, "live_chunk")
    assert refreshed.status == "awaiting_fallback"
    assert refreshed.input_mode == "live_chunks"
    assert refreshed.selected_final_input_mode == "live_chunks"
    assert chunk.process_status == "failed"
    assert chunk.retry_count == 3


def test_retry_exhausted_live_session_can_refinalize_into_fallback_and_complete(
    worker_harness: WorkerHarness, full_audio_file: Path
):
    session = worker_harness.seed_session_with_chunks(indexes=[0])
    worker_harness.attach_full_audio(session, full_audio_file)
    worker_harness.finalize(session.session_id, expected_chunk_count=1)
    transcriber = AlwaysFailingTranscriber()

    for _ in range(3):
        assert worker_harness.run_once(transcriber=transcriber) is True

    exhausted = worker_harness.fetch_session(session.session_id)
    exhausted_chunk = worker_harness.fetch_chunk(session.session_id, 0, "live_chunk")
    assert exhausted.status == "awaiting_fallback"
    assert exhausted_chunk.process_status == "failed"

    worker_harness.finalize(session.session_id, expected_chunk_count=1)
    worker_harness.run_until_idle()

    refreshed = worker_harness.fetch_session(session.session_id)
    fallback_chunks = worker_harness.list_chunks(
        session.session_id, "server_split_from_full_audio"
    )
    assert refreshed.selected_final_input_mode == "full_audio_fallback"
    assert refreshed.input_mode == "full_audio_fallback"
    assert refreshed.status == "completed"
    assert all(chunk.process_status == "completed" for chunk in fallback_chunks)


def test_stale_processing_recovery_only_resets_old_chunks(
    worker_harness: WorkerHarness,
):
    session = worker_harness.seed_session_with_chunks(indexes=[0, 1])
    worker_harness.mark_chunk_processing_state(
        session.session_id, 0, started_at_offset_seconds=301
    )
    worker_harness.mark_chunk_processing_state(
        session.session_id, 1, started_at_offset_seconds=30
    )

    assert worker_harness.run_once() is True

    stale_chunk = worker_harness.fetch_chunk(session.session_id, 0, "live_chunk")
    fresh_chunk = worker_harness.fetch_chunk(session.session_id, 1, "live_chunk")
    assert stale_chunk.process_status == "pending"
    assert "recovered stale processing chunk" in stale_chunk.error_message
    assert fresh_chunk.process_status == "processing"


def test_invalid_fallback_audio_marks_session_failed(
    worker_harness: WorkerHarness, invalid_full_audio_file: Path
):
    session = worker_harness.seed_session_with_missing_live_chunks()
    worker_harness.attach_full_audio(session, invalid_full_audio_file)

    worker_harness.finalize(session.session_id)
    assert worker_harness.run_once() is True

    refreshed = worker_harness.fetch_session(session.session_id)
    assert refreshed.status == "failed"
    assert "wav" in (refreshed.last_error or "").lower()


def test_zero_duration_fallback_audio_marks_session_failed(
    worker_harness: WorkerHarness, zero_duration_full_audio_file: Path
):
    session = worker_harness.seed_session_with_missing_live_chunks()
    worker_harness.attach_full_audio(session, zero_duration_full_audio_file)

    worker_harness.finalize(session.session_id)
    assert worker_harness.run_once() is True

    refreshed = worker_harness.fetch_session(session.session_id)
    assert refreshed.status == "failed"
    assert "zero chunks" in (refreshed.last_error or "").lower()


def test_partial_fallback_materialization_rolls_back_partial_chunks(
    worker_harness: WorkerHarness, full_audio_file: Path, monkeypatch
):
    session = worker_harness.seed_session_with_missing_live_chunks()
    worker_harness.attach_full_audio(session, full_audio_file)
    worker_harness.finalize(session.session_id)

    original_write_bytes = worker_harness.storage.write_bytes
    calls = 0

    def fail_on_second_fallback_write(logical_path: str, payload: bytes):
        nonlocal calls
        if "fallback-split-chunks" in logical_path:
            calls += 1
            if calls == 2:
                destination = worker_harness.storage.resolve(logical_path)
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes(payload[:8] or b"partial")
                raise OSError("simulated fallback storage failure")
        return original_write_bytes(logical_path, payload)

    monkeypatch.setattr(worker_harness.storage, "write_bytes", fail_on_second_fallback_write)

    assert worker_harness.run_once() is True

    refreshed = worker_harness.fetch_session(session.session_id)
    fallback_chunks = worker_harness.list_chunks(
        session.session_id, "server_split_from_full_audio"
    )
    fallback_chunk_path_0 = worker_harness.storage.session_path(
        session.session_id, "fallback-split-chunks", "0.wav"
    )
    fallback_chunk_path_1 = worker_harness.storage.session_path(
        session.session_id, "fallback-split-chunks", "1.wav"
    )
    assert refreshed.status == "failed"
    assert fallback_chunks == []
    assert worker_harness.storage.exists(fallback_chunk_path_0) is False
    assert worker_harness.storage.exists(fallback_chunk_path_1) is False
    assert "fallback wav materialization failed" in (refreshed.last_error or "")


def test_stale_recovery_resets_to_pending_without_consuming_retry_budget(
    worker_harness: WorkerHarness,
):
    session = worker_harness.seed_session_with_chunks(indexes=[0])
    worker_harness.set_chunk_retry_count(session.session_id, 0, 2)
    worker_harness.mark_chunk_processing_state(
        session.session_id, 0, started_at_offset_seconds=301
    )

    assert worker_harness.run_once() is True

    refreshed = worker_harness.fetch_session(session.session_id)
    chunk = worker_harness.fetch_chunk(session.session_id, 0, "live_chunk")
    assert refreshed.status == "receiving_chunks"
    assert chunk.process_status == "pending"
    assert chunk.retry_count == 2
    assert "recovered stale processing chunk" in (chunk.error_message or "")
