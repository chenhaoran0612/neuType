"""Add persisted storage path for speaker anchor artifacts."""

from __future__ import annotations

from alembic import op
import sqlalchemy as sa

revision = "20260420_04"
down_revision = "20260420_03"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column(
        "speaker_anchors",
        sa.Column(
            "anchor_storage_path",
            sa.String(length=512),
            nullable=True,
        ),
    )


def downgrade() -> None:
    op.drop_column("speaker_anchors", "anchor_storage_path")
