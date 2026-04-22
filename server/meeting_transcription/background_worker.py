"""Background worker thread for in-process chunk transcription."""

from __future__ import annotations

import logging
import threading

from sqlalchemy.orm import Session, sessionmaker

from meeting_transcription.storage import LocalArtifactStorage
from meeting_transcription.transcriber import ChunkTranscriber
from meeting_transcription.worker import run_pending_chunk_once

logger = logging.getLogger(__name__)


class BackgroundWorkerService:
    def __init__(
        self,
        *,
        session_factory: sessionmaker[Session],
        storage: LocalArtifactStorage,
        transcriber: ChunkTranscriber,
        idle_sleep_seconds: float = 1.0,
    ) -> None:
        self._session_factory = session_factory
        self._storage = storage
        self._transcriber = transcriber
        self._idle_sleep_seconds = idle_sleep_seconds
        self._stop_event = threading.Event()
        self._thread = threading.Thread(
            target=self._run,
            name="meeting-transcription-worker",
            daemon=True,
        )

    def start(self) -> None:
        if self._thread.is_alive():
            return
        self._thread.start()

    def stop(self) -> None:
        self._stop_event.set()
        if self._thread.is_alive():
            self._thread.join(timeout=5)

    def _run(self) -> None:
        while not self._stop_event.is_set():
            try:
                with self._session_factory() as db:
                    did_work = run_pending_chunk_once(
                        db,
                        self._transcriber,
                        storage=self._storage,
                    )
            except Exception:
                logger.exception("meeting transcription background worker loop failed")
                self._stop_event.wait(self._idle_sleep_seconds)
                continue

            if did_work:
                continue
            self._stop_event.wait(self._idle_sleep_seconds)
