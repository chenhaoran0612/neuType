from __future__ import annotations

import hashlib
from pathlib import Path
import wave

import pytest

from meeting_transcription.db import create_engine, create_session_factory
from meeting_transcription.models import Base, SessionChunk, TranscriptionSession
from meeting_transcription.storage import LocalArtifactStorage
from meeting_transcription.worker import run_pending_chunk_once


class StubTranscriber:
    def transcribe_chunk(self, *, session: TranscriptionSession, chunk: SessionChunk, audio_path: str):
        del audio_path
        return {
            "text": f"chunk-{chunk.chunk_index}",
            "segment_count": 1,
            "source_type": chunk.source_type,
            "session_id": session.session_id,
        }


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

    def run_once(self) -> bool:
        db = self.session_factory()
        try:
            return run_pending_chunk_once(db, self.transcriber, storage=self.storage)
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
