"""Local file storage helpers for meeting transcription artifacts."""

from __future__ import annotations

from pathlib import Path


class LocalArtifactStorage:
    """Persist session artifacts under a deterministic local root directory."""

    def __init__(self, root: str | Path) -> None:
        self.root = Path(root)

    def session_path(self, session_id: str, *parts: str) -> str:
        """Return a logical storage path rooted under the session directory."""
        relative_path = Path("sessions") / session_id
        for part in parts:
            relative_path /= part
        return relative_path.as_posix()

    def resolve(self, logical_path: str) -> Path:
        """Resolve a logical storage path to an absolute filesystem path."""
        return self.root / logical_path

    def write_bytes(self, logical_path: str, payload: bytes) -> Path:
        """Write bytes to the configured storage root."""
        destination = self.resolve(logical_path)
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(payload)
        return destination

    def exists(self, logical_path: str) -> bool:
        """Return whether the logical artifact exists on disk."""
        return self.resolve(logical_path).exists()
