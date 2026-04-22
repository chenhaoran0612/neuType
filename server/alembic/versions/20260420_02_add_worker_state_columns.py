"""Add worker state columns for fallback selection and commit ordering."""

from __future__ import annotations

from alembic import op
import sqlalchemy as sa

revision = "20260420_02"
down_revision = "20260420_01"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column(
        "transcription_sessions",
        sa.Column("selected_final_input_mode", sa.String(length=64), nullable=True),
    )
    op.add_column(
        "transcription_sessions",
        sa.Column("final_audio_storage_path", sa.String(length=512), nullable=True),
    )
    op.add_column(
        "transcription_sessions",
        sa.Column(
            "last_committed_chunk_index",
            sa.Integer(),
            nullable=False,
            server_default=sa.text("-1"),
        ),
    )
    op.add_column(
        "session_chunks",
        sa.Column("processing_started_at", sa.DateTime(timezone=True), nullable=True),
    )
    op.add_column(
        "session_chunks",
        sa.Column("processing_completed_at", sa.DateTime(timezone=True), nullable=True),
    )


def downgrade() -> None:
    op.drop_column("session_chunks", "processing_completed_at")
    op.drop_column("session_chunks", "processing_started_at")
    op.drop_column("transcription_sessions", "last_committed_chunk_index")
    op.drop_column("transcription_sessions", "final_audio_storage_path")
    op.drop_column("transcription_sessions", "selected_final_input_mode")
