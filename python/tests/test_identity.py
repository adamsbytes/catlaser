"""Tests for cat re-ID embedding comparison and catalog matching."""

from __future__ import annotations

import math
import struct
from pathlib import Path
from tempfile import TemporaryDirectory

import pytest

from catlaser_brain.identity.catalog import (
    EMBEDDING_BYTES,
    EMBEDDING_DIM,
    MATCH_THRESHOLD,
    CatCatalog,
    MatchResult,
    cosine_similarity,
    deserialize_embedding,
    serialize_embedding,
)
from catlaser_brain.storage.db import Database

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_EPS = 1e-7


def _make_embedding(seed_dim: int = 0, value: float = 1.0) -> tuple[float, ...]:
    """Create a 128-dim embedding with a single non-zero dimension, L2-normalized."""
    emb = [0.0] * EMBEDDING_DIM
    emb[seed_dim] = value
    norm = math.sqrt(sum(v * v for v in emb))
    if norm > 0.0:
        emb = [v / norm for v in emb]
    return tuple(emb)


def _make_spread_embedding(dims: dict[int, float]) -> tuple[float, ...]:
    """Create a 128-dim embedding with specified dimensions set, L2-normalized."""
    emb = [0.0] * EMBEDDING_DIM
    for dim, val in dims.items():
        emb[dim] = val
    norm = math.sqrt(sum(v * v for v in emb))
    if norm > 0.0:
        emb = [v / norm for v in emb]
    return tuple(emb)


def _to_bytes(emb: tuple[float, ...]) -> bytes:
    """Serialize a 128-dim embedding to raw LE f32 bytes."""
    return serialize_embedding(emb)


def _db_with_catalog(tmpdir: str) -> tuple[Database, CatCatalog]:
    """Create a fresh database and catalog in the given temp directory."""
    db = Database.connect(Path(tmpdir) / "test.db")
    catalog = CatCatalog(db)
    return db, catalog


# ---------------------------------------------------------------------------
# Serialization round-trip
# ---------------------------------------------------------------------------


class TestSerialization:
    def test_round_trip_identity(self):
        emb = _make_embedding(seed_dim=0)
        raw = serialize_embedding(emb)
        recovered = deserialize_embedding(raw)
        for orig, rec in zip(emb, recovered, strict=True):
            assert abs(orig - rec) < _EPS

    def test_round_trip_all_dims(self):
        emb = tuple(float(i) for i in range(EMBEDDING_DIM))
        raw = serialize_embedding(emb)
        recovered = deserialize_embedding(raw)
        assert len(recovered) == EMBEDDING_DIM
        for i in range(EMBEDDING_DIM):
            assert abs(emb[i] - recovered[i]) < _EPS

    def test_serialized_length(self):
        emb = _make_embedding()
        raw = serialize_embedding(emb)
        assert len(raw) == EMBEDDING_BYTES

    def test_byte_format_matches_rust_le_f32(self):
        emb = _make_embedding(seed_dim=0, value=1.0)
        raw = serialize_embedding(emb)
        first_float: float = struct.unpack_from("<f", raw, 0)[0]
        assert abs(first_float - emb[0]) < _EPS

    def test_deserialize_wrong_length_short(self):
        with pytest.raises(ValueError, match="512 bytes"):
            deserialize_embedding(b"\x00" * 100)

    def test_deserialize_wrong_length_long(self):
        with pytest.raises(ValueError, match="512 bytes"):
            deserialize_embedding(b"\x00" * 600)

    def test_serialize_wrong_dim(self):
        with pytest.raises(ValueError, match="128 elements"):
            serialize_embedding(tuple(range(64)))


# ---------------------------------------------------------------------------
# Cosine similarity
# ---------------------------------------------------------------------------


class TestCosineSimilarity:
    def test_identical_vectors(self):
        emb = _make_embedding(seed_dim=5)
        assert abs(cosine_similarity(emb, emb) - 1.0) < _EPS

    def test_orthogonal_vectors(self):
        a = _make_embedding(seed_dim=0)
        b = _make_embedding(seed_dim=1)
        assert abs(cosine_similarity(a, b)) < _EPS

    def test_opposite_vectors(self):
        a = _make_embedding(seed_dim=0, value=1.0)
        b = _make_embedding(seed_dim=0, value=-1.0)
        assert abs(cosine_similarity(a, b) - (-1.0)) < _EPS

    def test_similar_vectors_high_similarity(self):
        a = _make_spread_embedding({0: 1.0, 1: 0.1})
        b = _make_spread_embedding({0: 1.0, 1: 0.2})
        sim = cosine_similarity(a, b)
        assert sim > 0.99

    def test_dissimilar_vectors_low_similarity(self):
        a = _make_spread_embedding({0: 1.0, 1: 0.0})
        b = _make_spread_embedding({0: 0.0, 1: 1.0})
        sim = cosine_similarity(a, b)
        assert abs(sim) < _EPS

    def test_zero_vector_returns_zero(self):
        zero = tuple([0.0] * EMBEDDING_DIM)
        nonzero = _make_embedding(seed_dim=0)
        assert abs(cosine_similarity(zero, nonzero)) < _EPS
        assert abs(cosine_similarity(nonzero, zero)) < _EPS
        assert abs(cosine_similarity(zero, zero)) < _EPS


# ---------------------------------------------------------------------------
# Empty catalog
# ---------------------------------------------------------------------------


class TestEmptyCatalog:
    def test_match_returns_unknown(self):
        with TemporaryDirectory() as tmpdir:
            db, catalog = _db_with_catalog(tmpdir)
            try:
                emb = _make_embedding(seed_dim=0)
                result = catalog.match_embedding(_to_bytes(emb), 0.9)
                assert result.cat_id == ""
                assert result.similarity < 0.0
            finally:
                db.close()

    def test_match_result_type(self):
        with TemporaryDirectory() as tmpdir:
            db, catalog = _db_with_catalog(tmpdir)
            try:
                emb = _make_embedding(seed_dim=0)
                result = catalog.match_embedding(_to_bytes(emb), 0.9)
                assert isinstance(result, MatchResult)
            finally:
                db.close()


# ---------------------------------------------------------------------------
# Known cat matching
# ---------------------------------------------------------------------------


class TestKnownCatMatch:
    def test_match_single_cat(self):
        with TemporaryDirectory() as tmpdir:
            db, catalog = _db_with_catalog(tmpdir)
            try:
                stored_emb = _make_spread_embedding({0: 1.0, 1: 0.1, 2: 0.05})
                catalog.add_cat("cat-1", "Whiskers", b"\xff\xd8thumbnail", _to_bytes(stored_emb))

                query_emb = _make_spread_embedding({0: 1.0, 1: 0.12, 2: 0.04})
                result = catalog.match_embedding(_to_bytes(query_emb), 0.95)

                assert result.cat_id == "cat-1"
                assert result.similarity > MATCH_THRESHOLD
            finally:
                db.close()

    def test_match_picks_best_of_two_cats(self):
        with TemporaryDirectory() as tmpdir:
            db, catalog = _db_with_catalog(tmpdir)
            try:
                emb_a = _make_spread_embedding({0: 1.0, 1: 0.1})
                catalog.add_cat("cat-a", "Luna", b"\xff\xd8luna", _to_bytes(emb_a))

                emb_b = _make_spread_embedding({2: 1.0, 3: 0.1})
                catalog.add_cat("cat-b", "Milo", b"\xff\xd8milo", _to_bytes(emb_b))

                query = _make_spread_embedding({0: 1.0, 1: 0.15})
                result = catalog.match_embedding(_to_bytes(query), 0.9)

                assert result.cat_id == "cat-a"
                assert result.similarity > MATCH_THRESHOLD
            finally:
                db.close()

    def test_below_threshold_returns_unknown(self):
        with TemporaryDirectory() as tmpdir:
            db, catalog = _db_with_catalog(tmpdir)
            try:
                stored = _make_embedding(seed_dim=0)
                catalog.add_cat("cat-1", "Shadow", b"\xff\xd8shadow", _to_bytes(stored))

                query = _make_embedding(seed_dim=64)
                result = catalog.match_embedding(_to_bytes(query), 0.9)

                assert result.cat_id == ""
                assert result.similarity < MATCH_THRESHOLD
            finally:
                db.close()

    def test_reverify_after_coasting(self):
        """Same cat re-identified after track coasting and re-acquisition."""
        with TemporaryDirectory() as tmpdir:
            db, catalog = _db_with_catalog(tmpdir)
            try:
                emb = _make_spread_embedding({0: 1.0, 1: 0.2, 2: 0.05})
                catalog.add_cat("cat-1", "Pepper", b"\xff\xd8pepper", _to_bytes(emb))

                # First identification.
                query1 = _make_spread_embedding({0: 1.0, 1: 0.18, 2: 0.06})
                result1 = catalog.match_embedding(_to_bytes(query1), 0.93)
                assert result1.cat_id == "cat-1"

                # Re-verification (slightly different embedding from new crop).
                query2 = _make_spread_embedding({0: 1.0, 1: 0.22, 2: 0.04})
                result2 = catalog.match_embedding(_to_bytes(query2), 0.91)
                assert result2.cat_id == "cat-1"
                assert result2.similarity > MATCH_THRESHOLD
            finally:
                db.close()


# ---------------------------------------------------------------------------
# Multiple stored embeddings per cat
# ---------------------------------------------------------------------------


class TestMultipleEmbeddings:
    def test_averaged_embeddings_still_match(self):
        with TemporaryDirectory() as tmpdir:
            db, catalog = _db_with_catalog(tmpdir)
            try:
                base = _make_spread_embedding({0: 1.0, 1: 0.1})
                catalog.add_cat("cat-1", "Oreo", b"\xff\xd8oreo", _to_bytes(base))

                # Store two more embeddings (slightly different crops).
                variant1 = _make_spread_embedding({0: 1.0, 1: 0.15})
                catalog.store_embedding("cat-1", _to_bytes(variant1))
                variant2 = _make_spread_embedding({0: 1.0, 1: 0.08})
                catalog.store_embedding("cat-1", _to_bytes(variant2))

                # Query with a similar embedding.
                query = _make_spread_embedding({0: 1.0, 1: 0.12})
                result = catalog.match_embedding(_to_bytes(query), 0.9)

                assert result.cat_id == "cat-1"
                assert result.similarity > MATCH_THRESHOLD
            finally:
                db.close()

    def test_store_embedding_increases_count(self):
        with TemporaryDirectory() as tmpdir:
            db, catalog = _db_with_catalog(tmpdir)
            try:
                emb = _make_embedding(seed_dim=0)
                catalog.add_cat("cat-1", "Gizmo", b"\xff\xd8gizmo", _to_bytes(emb))

                count_before = db.conn.execute(
                    "SELECT COUNT(*) FROM cat_embeddings WHERE cat_id = ?",
                    ("cat-1",),
                ).fetchone()[0]
                assert count_before == 1

                catalog.store_embedding("cat-1", _to_bytes(emb))

                count_after = db.conn.execute(
                    "SELECT COUNT(*) FROM cat_embeddings WHERE cat_id = ?",
                    ("cat-1",),
                ).fetchone()[0]
                assert count_after == 2
            finally:
                db.close()


# ---------------------------------------------------------------------------
# add_cat
# ---------------------------------------------------------------------------


class TestAddCat:
    def test_creates_cat_and_embedding(self):
        with TemporaryDirectory() as tmpdir:
            db, catalog = _db_with_catalog(tmpdir)
            try:
                emb = _make_embedding(seed_dim=3)
                catalog.add_cat("cat-99", "Felix", b"\xff\xd8felix", _to_bytes(emb))

                cat_row = db.conn.execute(
                    "SELECT name FROM cats WHERE cat_id = ?", ("cat-99",)
                ).fetchone()
                assert cat_row is not None
                assert cat_row["name"] == "Felix"

                emb_row = db.conn.execute(
                    "SELECT embedding FROM cat_embeddings WHERE cat_id = ?", ("cat-99",)
                ).fetchone()
                assert emb_row is not None
                assert len(emb_row["embedding"]) == EMBEDDING_BYTES
            finally:
                db.close()

    def test_thumbnail_stored(self):
        with TemporaryDirectory() as tmpdir:
            db, catalog = _db_with_catalog(tmpdir)
            try:
                emb = _make_embedding()
                thumbnail = b"\xff\xd8\xff\xe0fake-jpeg-data"
                catalog.add_cat("cat-1", "Nala", thumbnail, _to_bytes(emb))

                row = db.conn.execute(
                    "SELECT thumbnail FROM cats WHERE cat_id = ?", ("cat-1",)
                ).fetchone()
                assert row is not None
                assert row["thumbnail"] == thumbnail
            finally:
                db.close()

    def test_add_cat_bad_embedding_length(self):
        with TemporaryDirectory() as tmpdir:
            db, catalog = _db_with_catalog(tmpdir)
            try:
                with pytest.raises(ValueError, match="512 bytes"):
                    catalog.add_cat("cat-1", "Bad", b"\xff\xd8thumb", b"\x00" * 100)
            finally:
                db.close()


# ---------------------------------------------------------------------------
# store_embedding validation
# ---------------------------------------------------------------------------


class TestStoreEmbeddingValidation:
    def test_wrong_length_rejected(self):
        with TemporaryDirectory() as tmpdir:
            db, catalog = _db_with_catalog(tmpdir)
            try:
                emb = _make_embedding()
                catalog.add_cat("cat-1", "Test", b"\xff\xd8test", _to_bytes(emb))

                with pytest.raises(ValueError, match="512 bytes"):
                    catalog.store_embedding("cat-1", b"\x00" * 256)
            finally:
                db.close()


# ---------------------------------------------------------------------------
# match_embedding validation
# ---------------------------------------------------------------------------


class TestMatchEmbeddingValidation:
    def test_wrong_length_rejected(self):
        with TemporaryDirectory() as tmpdir:
            db, catalog = _db_with_catalog(tmpdir)
            try:
                with pytest.raises(ValueError, match="512 bytes"):
                    catalog.match_embedding(b"\x00" * 100, 0.9)
            finally:
                db.close()


# ---------------------------------------------------------------------------
# Three-cat disambiguation
# ---------------------------------------------------------------------------


class TestThreeCatDisambiguation:
    def test_correct_cat_selected_among_three(self):
        with TemporaryDirectory() as tmpdir:
            db, catalog = _db_with_catalog(tmpdir)
            try:
                # Three cats with embeddings in distinct regions of the space.
                emb_a = _make_spread_embedding({0: 1.0, 1: 0.1})
                catalog.add_cat("cat-a", "Luna", b"\xff\xd8luna", _to_bytes(emb_a))

                emb_b = _make_spread_embedding({40: 1.0, 41: 0.1})
                catalog.add_cat("cat-b", "Milo", b"\xff\xd8milo", _to_bytes(emb_b))

                emb_c = _make_spread_embedding({80: 1.0, 81: 0.1})
                catalog.add_cat("cat-c", "Nala", b"\xff\xd8nala", _to_bytes(emb_c))

                # Query near cat-b.
                query = _make_spread_embedding({40: 1.0, 41: 0.15})
                result = catalog.match_embedding(_to_bytes(query), 0.9)

                assert result.cat_id == "cat-b"
                assert result.similarity > MATCH_THRESHOLD
            finally:
                db.close()
