"""Create meeting transcription persistence tables."""

from __future__ import annotations

from alembic import op
import sqlalchemy as sa

revision = "20260420_01"
down_revision = None
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "transcription_sessions",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("session_id", sa.String(length=255), nullable=False),
        sa.Column("client_session_token", sa.String(length=255), nullable=False),
        sa.Column("status", sa.String(length=64), nullable=False),
        sa.Column("input_mode", sa.String(length=64), nullable=False),
        sa.Column("chunk_duration_ms", sa.Integer(), nullable=False),
        sa.Column("chunk_overlap_ms", sa.Integer(), nullable=False),
        sa.Column("expected_chunk_count", sa.Integer(), nullable=True),
        sa.Column("selected_final_input_mode", sa.String(length=64), nullable=True),
        sa.Column(
            "final_audio_uploaded",
            sa.Boolean(),
            nullable=False,
            server_default=sa.false(),
        ),
        sa.Column("final_audio_sha256", sa.String(length=128), nullable=True),
        sa.Column("final_audio_storage_path", sa.String(length=512), nullable=True),
        sa.Column(
            "last_committed_chunk_index",
            sa.Integer(),
            nullable=False,
            server_default=sa.text("-1"),
        ),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            nullable=False,
            server_default=sa.text("CURRENT_TIMESTAMP"),
        ),
        sa.Column(
            "updated_at",
            sa.DateTime(timezone=True),
            nullable=False,
            server_default=sa.text("CURRENT_TIMESTAMP"),
        ),
        sa.Column("finalized_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("last_error", sa.Text(), nullable=True),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_transcription_sessions")),
        sa.UniqueConstraint("client_session_token", name=op.f("uq_transcription_sessions_client_session_token")),
        sa.UniqueConstraint("session_id", name=op.f("uq_transcription_sessions_session_id")),
    )

    op.create_table(
        "session_chunks",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("session_id", sa.Uuid(), nullable=False),
        sa.Column("chunk_index", sa.Integer(), nullable=False),
        sa.Column("source_type", sa.String(length=64), nullable=False),
        sa.Column("start_ms", sa.Integer(), nullable=False),
        sa.Column("end_ms", sa.Integer(), nullable=False),
        sa.Column("duration_ms", sa.Integer(), nullable=False),
        sa.Column("sha256", sa.String(length=128), nullable=False),
        sa.Column("storage_path", sa.String(length=512), nullable=False),
        sa.Column("upload_status", sa.String(length=64), nullable=False),
        sa.Column("process_status", sa.String(length=64), nullable=False),
        sa.Column(
            "retry_count",
            sa.Integer(),
            nullable=False,
            server_default=sa.text("0"),
        ),
        sa.Column("result_segment_count", sa.Integer(), nullable=True),
        sa.Column("error_message", sa.Text(), nullable=True),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            nullable=False,
            server_default=sa.text("CURRENT_TIMESTAMP"),
        ),
        sa.Column(
            "updated_at",
            sa.DateTime(timezone=True),
            nullable=False,
            server_default=sa.text("CURRENT_TIMESTAMP"),
        ),
        sa.ForeignKeyConstraint(
            ["session_id"],
            ["transcription_sessions.id"],
            name=op.f("fk_session_chunks_session_id_transcription_sessions"),
            ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_session_chunks")),
        sa.UniqueConstraint(
            "session_id",
            "chunk_index",
            "source_type",
            name="uq_session_chunks_session_id_chunk_index_source_type",
        ),
    )


def downgrade() -> None:
    op.drop_table("session_chunks")
    op.drop_table("transcription_sessions")
