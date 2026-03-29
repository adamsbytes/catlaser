"""Cat re-ID catalog: embedding comparison and identity resolution.

Receives 128-dim embedding vectors from the Rust vision daemon (via
``IdentityRequest``), compares against stored per-cat embeddings in SQLite,
and returns an ``IdentityResult`` indicating either a known cat match or
an unknown cat requiring user naming.

Embeddings arrive as 512 raw bytes (128 little-endian f32s), matching the
Rust-side ``embedding_to_bytes`` serialization. All vectors are L2-normalized
by the Rust embedding engine, so cosine similarity reduces to a dot product.

Stored embeddings are maintained as a fixed-size reservoir sample per cat
(Algorithm R). This gives a representative spread across all conditions the
cat has been observed in (lighting, pose, angle, seasonal coat) rather than
biasing toward the most recent observations.
"""

from __future__ import annotations

import math
import random
import struct
import time
from typing import TYPE_CHECKING, Final, NamedTuple

if TYPE_CHECKING:
    import sqlite3

    from catlaser_brain.storage.db import Database

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

EMBEDDING_DIM: Final[int] = 128
"""Number of float32 elements in an embedding vector."""

EMBEDDING_BYTES: Final[int] = EMBEDDING_DIM * 4
"""Expected byte length of a serialized embedding (512 bytes)."""

MATCH_THRESHOLD: Final[float] = 0.75
"""Cosine similarity above which a match is considered confident."""

MAX_EMBEDDINGS_PER_CAT: Final[int] = 30
"""Maximum stored embeddings per cat (reservoir size)."""

_UNPACK_FMT: Final[str] = f"<{EMBEDDING_DIM}f"
"""``struct`` format string: 128 little-endian f32s."""

_UNPACK_STRUCT: Final[struct.Struct] = struct.Struct(_UNPACK_FMT)
"""Pre-compiled struct for embedding deserialization."""


# ---------------------------------------------------------------------------
# Embedding math (pure Python, no numpy — this runs on a Cortex-A7)
# ---------------------------------------------------------------------------


def deserialize_embedding(raw: bytes) -> tuple[float, ...]:
    """Deserialize 512 raw bytes into a 128-dim float tuple.

    Args:
        raw: Little-endian f32 bytes from ``IdentityRequest.embedding``.

    Returns:
        Tuple of 128 floats.

    Raises:
        ValueError: If *raw* is not exactly 512 bytes.
    """
    if len(raw) != EMBEDDING_BYTES:
        msg = f"embedding must be {EMBEDDING_BYTES} bytes, got {len(raw)}"
        raise ValueError(msg)
    return _UNPACK_STRUCT.unpack(raw)


def serialize_embedding(embedding: tuple[float, ...] | list[float]) -> bytes:
    """Serialize a 128-dim embedding to 512 raw little-endian f32 bytes.

    Args:
        embedding: 128 float values.

    Returns:
        512 bytes.

    Raises:
        ValueError: If *embedding* does not have exactly 128 elements.
    """
    if len(embedding) != EMBEDDING_DIM:
        msg = f"embedding must have {EMBEDDING_DIM} elements, got {len(embedding)}"
        raise ValueError(msg)
    return _UNPACK_STRUCT.pack(*embedding)


def cosine_similarity(a: tuple[float, ...], b: tuple[float, ...]) -> float:
    """Cosine similarity between two vectors.

    Both vectors are expected to be L2-normalized (as produced by the Rust
    embedding engine), so this is a simple dot product. The normalization
    denominator is still computed for correctness if vectors are not perfectly
    unit-length due to float precision.

    Args:
        a: First embedding vector.
        b: Second embedding vector.

    Returns:
        Similarity in [-1.0, 1.0].
    """
    dot = 0.0
    norm_a = 0.0
    norm_b = 0.0
    for va, vb in zip(a, b, strict=True):
        dot += va * vb
        norm_a += va * va
        norm_b += vb * vb
    denom = math.sqrt(norm_a) * math.sqrt(norm_b)
    if denom == 0.0:
        return 0.0
    return dot / denom


def _average_embeddings(embeddings: list[tuple[float, ...]]) -> tuple[float, ...]:
    """Element-wise average of multiple embeddings, then L2-normalize.

    Args:
        embeddings: Non-empty list of 128-dim tuples.

    Returns:
        Averaged, L2-normalized embedding.
    """
    count = len(embeddings)
    avg = [0.0] * EMBEDDING_DIM
    for emb in embeddings:
        for i, v in enumerate(emb):
            avg[i] += v
    for i in range(EMBEDDING_DIM):
        avg[i] /= count

    # L2-normalize the average.
    norm = math.sqrt(sum(v * v for v in avg))
    if norm > 0.0:
        avg = [v / norm for v in avg]

    return tuple(avg)


# ---------------------------------------------------------------------------
# Match result
# ---------------------------------------------------------------------------


class MatchResult(NamedTuple):
    """Result of comparing an embedding against the catalog.

    Attributes:
        cat_id: Resolved cat ID, or empty string for unknown/new cat.
        similarity: Best cosine similarity score. Negative if catalog is empty.
    """

    cat_id: str
    similarity: float


# ---------------------------------------------------------------------------
# Catalog
# ---------------------------------------------------------------------------


class CatCatalog:
    """Cat identity catalog backed by SQLite.

    Compares incoming embeddings against stored per-cat embedding profiles
    and resolves track identity. Not thread-safe — designed for single-threaded
    use within the Python behavior engine event loop.

    Deserialized embeddings are cached in memory and invalidated on mutation
    (``store_embedding``, ``add_cat``). The catalog is small (a few cats, up
    to ``MAX_EMBEDDINGS_PER_CAT`` each) so the cache is always complete.

    Args:
        db: Database handle with migrations already applied.
    """

    __slots__ = ("_cache", "_db")

    def __init__(self, db: Database) -> None:
        self._db = db
        self._cache: dict[str, list[tuple[float, ...]]] | None = None

    def match_embedding(
        self,
        embedding_bytes: bytes,
        _confidence: float,
    ) -> MatchResult:
        """Compare an embedding against all stored cat profiles.

        Loads stored embeddings (from cache or SQLite), averages per-cat,
        and returns the best cosine-similarity match (or unknown if below
        threshold or catalog is empty).

        Args:
            embedding_bytes: Raw 512-byte embedding from ``IdentityRequest``.
            _confidence: Embedding model confidence (reserved for future
                weighting; currently unused).

        Returns:
            Match result with resolved cat_id and similarity.

        Raises:
            ValueError: If *embedding_bytes* is not exactly 512 bytes.
        """
        query_emb = deserialize_embedding(embedding_bytes)
        catalog = self._get_catalog()

        if not catalog:
            return MatchResult(cat_id="", similarity=-1.0)

        best_cat_id = ""
        best_similarity = -1.0

        for cat_id, stored_embeddings in catalog.items():
            avg_emb = _average_embeddings(stored_embeddings)
            sim = cosine_similarity(query_emb, avg_emb)
            if sim > best_similarity:
                best_similarity = sim
                best_cat_id = cat_id

        if best_similarity < MATCH_THRESHOLD:
            return MatchResult(cat_id="", similarity=best_similarity)

        return MatchResult(cat_id=best_cat_id, similarity=best_similarity)

    def store_embedding(self, cat_id: str, embedding_bytes: bytes) -> None:
        """Store a new embedding for an existing cat using reservoir sampling.

        Maintains a fixed-size reservoir of ``MAX_EMBEDDINGS_PER_CAT``
        embeddings per cat. Uses Algorithm R: the first N embeddings fill
        the reservoir directly; subsequent embeddings are accepted with
        probability N/n (where n is total embeddings ever observed for this
        cat), replacing a uniformly random existing entry.

        This produces a representative spread across all conditions the cat
        has been observed in, rather than biasing toward recent observations.

        Args:
            cat_id: The cat to associate this embedding with.
            embedding_bytes: Raw 512-byte embedding.

        Raises:
            ValueError: If *embedding_bytes* is not exactly 512 bytes.
        """
        if len(embedding_bytes) != EMBEDDING_BYTES:
            msg = f"embedding must be {EMBEDDING_BYTES} bytes, got {len(embedding_bytes)}"
            raise ValueError(msg)

        conn = self._db.conn
        now = int(time.time())

        # Increment total-seen counter and read the new value.
        conn.execute(
            "UPDATE cats SET embeddings_seen = embeddings_seen + 1 WHERE cat_id = ?",
            (cat_id,),
        )
        row = conn.execute(
            "SELECT embeddings_seen FROM cats WHERE cat_id = ?",
            (cat_id,),
        ).fetchone()
        embeddings_seen: int = row["embeddings_seen"]

        # Count currently stored embeddings.
        count_row = conn.execute(
            "SELECT COUNT(*) FROM cat_embeddings WHERE cat_id = ?",
            (cat_id,),
        ).fetchone()
        stored_count: int = count_row[0]

        if stored_count < MAX_EMBEDDINGS_PER_CAT:
            # Reservoir not full — insert directly.
            conn.execute(
                "INSERT INTO cat_embeddings (cat_id, embedding, captured_at) VALUES (?, ?, ?)",
                (cat_id, embedding_bytes, now),
            )
        elif random.random() < MAX_EMBEDDINGS_PER_CAT / embeddings_seen:  # noqa: S311
            # Reservoir full — accept with probability k/n, replace random entry.
            ids: list[int] = [
                r[0]
                for r in conn.execute(
                    "SELECT id FROM cat_embeddings WHERE cat_id = ?",
                    (cat_id,),
                ).fetchall()
            ]
            replace_id = random.choice(ids)  # noqa: S311
            conn.execute(
                "UPDATE cat_embeddings SET embedding = ?, captured_at = ? WHERE id = ?",
                (embedding_bytes, now, replace_id),
            )

        conn.commit()
        self._cache = None

    def add_cat(
        self,
        cat_id: str,
        name: str,
        thumbnail: bytes,
        embedding_bytes: bytes,
    ) -> None:
        """Register a new cat in the catalog.

        Inserts into both ``cats`` and ``cat_embeddings`` atomically.
        Initializes ``embeddings_seen`` to 1 for the seed embedding.

        Args:
            cat_id: Unique cat identifier (e.g. UUID).
            name: User-provided cat name.
            thumbnail: JPEG thumbnail crop of the cat.
            embedding_bytes: Raw 512-byte embedding from the initial detection.

        Raises:
            ValueError: If *embedding_bytes* is not exactly 512 bytes.
        """
        if len(embedding_bytes) != EMBEDDING_BYTES:
            msg = f"embedding must be {EMBEDDING_BYTES} bytes, got {len(embedding_bytes)}"
            raise ValueError(msg)
        now = int(time.time())
        conn = self._db.conn
        conn.execute(
            """INSERT INTO cats
               (cat_id, name, thumbnail, embeddings_seen, created_at, updated_at)
               VALUES (?, ?, ?, 1, ?, ?)""",
            (cat_id, name, thumbnail, now, now),
        )
        conn.execute(
            "INSERT INTO cat_embeddings (cat_id, embedding, captured_at) VALUES (?, ?, ?)",
            (cat_id, embedding_bytes, now),
        )
        conn.commit()
        self._cache = None

    def _get_catalog(self) -> dict[str, list[tuple[float, ...]]]:
        """Return cached catalog, loading from SQLite on first access or after invalidation."""
        if self._cache is not None:
            return self._cache
        self._cache = self._load_catalog_embeddings()
        return self._cache

    def _load_catalog_embeddings(self) -> dict[str, list[tuple[float, ...]]]:
        """Load all stored embeddings grouped by cat_id.

        Returns:
            Mapping of cat_id to list of deserialized embedding tuples.
        """
        conn = self._db.conn
        rows: list[sqlite3.Row] = conn.execute(
            "SELECT cat_id, embedding FROM cat_embeddings ORDER BY cat_id",
        ).fetchall()

        catalog: dict[str, list[tuple[float, ...]]] = {}
        for row in rows:
            cat_id: str = row["cat_id"]
            raw: bytes = row["embedding"]
            emb = deserialize_embedding(raw)
            if cat_id not in catalog:
                catalog[cat_id] = []
            catalog[cat_id].append(emb)

        return catalog
