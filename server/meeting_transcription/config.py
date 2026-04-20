"""Configuration scaffold for the meeting transcription service."""

from dataclasses import dataclass


@dataclass(frozen=True)
class Settings:
    """Application settings."""

    service_name: str = "meeting-transcription"
