"""Add speaker anchor persistence and normalized worker output columns."""

from __future__ import annotations

from alembic import op
import sqlalchemy as sa

revision = "20260420_03"
down_revision = "20260420_02"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column(
        "session_chunks",
        sa.Column("prepared_prefix_manifest_json", sa.Text(), nullable=True),
    )
    op.add_column(
        "session_chunks",
        sa.Column("normalized_segments_json", sa.Text(), nullable=True),
    )
    op.create_table(
        "speaker_anchors",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("session_id", sa.Uuid(), nullable=False),
        sa.Column("speaker_key", sa.String(length=255), nullable=False),
        sa.Column("anchor_order", sa.Integer(), nullable=False),
        sa.Column("source_chunk_index", sa.Integer(), nullable=False),
        sa.Column("anchor_text", sa.Text(), nullable=False),
        sa.Column("anchor_start_ms", sa.Integer(), nullable=False),
        sa.Column("anchor_end_ms", sa.Integer(), nullable=False),
        sa.Column("anchor_duration_ms", sa.Integer(), nullable=False),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            nullable=False,
            server_default=sa.text("CURRENT_TIMESTAMP"),
        ),
        sa.ForeignKeyConstraint(
            ["session_id"],
            ["transcription_sessions.id"],
            name=op.f("fk_speaker_anchors_session_id_transcription_sessions"),
            ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_speaker_anchors")),
        sa.UniqueConstraint(
            "session_id",
            "speaker_key",
            name="uq_speaker_anchors_session_id_speaker_key",
        ),
        sa.UniqueConstraint(
            "session_id",
            "anchor_order",
            name="uq_speaker_anchors_session_id_anchor_order",
        ),
    )


def downgrade() -> None:
    op.drop_table("speaker_anchors")
    op.drop_column("session_chunks", "normalized_segments_json")
    op.drop_column("session_chunks", "prepared_prefix_manifest_json")
