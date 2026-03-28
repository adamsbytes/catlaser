# Buffa Protobuf Crate — Research Notes

**Crate:** `buffa` (v0.2.0, pre-1.0, Apache-2.0)
**Repo:** [github.com/anthropics/buffa](https://github.com/anthropics/buffa)
**MSRV:** Rust 1.85 | **`no_std`** supported (requires `alloc`)

Buffa is Anthropic's pure-Rust Protocol Buffers implementation with first-class editions support, proto3 JSON via serde, and zero-copy message views. It targets codegen-first workflows (no runtime reflection) and passes the protobuf conformance suite (v33.5, editions through 2024).

---

## Codegen Output Patterns

### Build pipelines

Two paths produce identical output:

1. **`buf generate`** (recommended) — uses `protoc-gen-buffa` + `protoc-gen-buffa-packaging` as local plugins. No `protoc` install required; `buf` has a built-in compiler.
2. **`buffa-build`** — a `build.rs` helper similar to `prost-build`. Requires `protoc` on PATH (or `buf` via `.use_buf()`).

The packaging plugin emits a `mod.rs` with nested `pub mod` blocks and `#![allow(...)]` attributes, so no hand-written bridge file is needed.

### Generated struct shape

For a message like:

```proto
message DetectionFrame {
  int64 timestamp_us = 1;
  repeated BoundingBox detections = 2;
  string model_id = 3;
  optional float confidence_threshold = 4;
}
```

Buffa emits:

```rust
pub struct DetectionFrame {
    pub timestamp_us: i64,
    pub detections: Vec<BoundingBox>,
    pub model_id: String,
    pub confidence_threshold: Option<f32>,
    #[doc(hidden)] pub __buffa_unknown_fields: buffa::UnknownFields,
    #[doc(hidden)] pub __buffa_cached_size: buffa::__private::CachedSize,
}
```

Key differences from prost:

- **`MessageField<T>`** for singular sub-message fields (wraps `Option<Box<T>>` but `Deref`s to a static default instance when unset — no `.unwrap()` ceremony).
- **`EnumValue<E>`** for proto3 open enums (distinguishes `Known(E)` vs `Unknown(i32)`; implements `PartialEq<E>` for direct comparison).
- **`__buffa_unknown_fields`** preserves unrecognized fields for round-trip fidelity (can be disabled via `.preserve_unknown_fields(false)` to save 24 bytes/message).
- **`__buffa_cached_size`** enables two-pass serialization: `compute_size()` caches sub-message sizes bottom-up, then `write_to()` uses them. This avoids the exponential re-computation that prost has with deeply nested messages.
- **Module nesting** mirrors proto nesting (`outer::Inner`, not `OuterInner`).
- **Oneofs** become Rust enums scoped in the parent's module. Message variants are always `Box`ed. `From<T>` impls are generated for unambiguous variants.

### Codegen config flags relevant to embedded/`no_std`

| Flag                         | Default | Notes for your project                                     |
|------------------------------|---------|------------------------------------------------------------|
| `.generate_views(bool)`      | `true`  | Zero-copy view types — useful for the Luckfox side         |
| `.preserve_unknown_fields()` | `true`  | Disable on the MCU side to save 24 bytes/message           |
| `.generate_json(bool)`       | `false` | Only needed if you want proto3 JSON (unlikely for UART)    |
| `.strict_utf8_mapping(bool)` | `false` | Maps `utf8_validation=NONE` strings to `Vec<u8>`/`&[u8]`  |
| `.generate_arbitrary(bool)`  | `false` | Adds `arbitrary::Arbitrary` derives for fuzz testing       |

---

## Serialization / Deserialization API

All generated structs implement `buffa::Message`:

```rust
use buffa::Message;

// Encode
let bytes: Vec<u8> = frame.encode_to_vec();
let bytes: bytes::Bytes = frame.encode_to_bytes(); // zero-copy, for networking
frame.encode(&mut buf); // into any BufMut

// Decode
let frame = DetectionFrame::decode_from_slice(&bytes)?;
let frame = DetectionFrame::decode(&mut buf)?; // from any Buf

// Merge (last-write-wins for scalars, append for repeated,
//        recursive merge for sub-messages)
frame.merge_from_slice(&more_bytes)?;

// Clear to defaults
frame.clear();
```

Encoding is **infallible** — `encode()` never returns an error. Decoding returns `Result<T, DecodeError>` with variants like `UnexpectedEof`, `VarintTooLong`, `WireTypeMismatch`, `RecursionLimitExceeded`, `MessageTooLarge`.

### Decode options (security-relevant)

```rust
use buffa::DecodeOptions;

let frame = DecodeOptions::new()
    .with_recursion_limit(20)       // default: 100
    .with_max_message_size(64_000)  // default: ~2 GiB
    .decode_from_slice::<DetectionFrame>(&bytes)?;
```

Prost uses a fixed recursion limit of 100 with no override; buffa makes both recursion and size limits configurable. This matters for the Luckfox since it's accepting data from the network.

---

## Zero-Copy View Types

This is the most relevant feature for your architecture. For every generated message `Foo`, buffa also generates `FooView<'a>` (enabled by default, controlled by `.generate_views(true)`):

```rust
pub struct DetectionFrameView<'a> {
    pub timestamp_us: i64,                              // scalar: decoded by value
    pub detections: buffa::RepeatedView<'a, BoundingBoxView<'a>>,
    pub model_id: &'a str,                              // borrowed from input buffer
    pub confidence_threshold: Option<f32>,
}
```

Usage:

```rust
use buffa::MessageView;

// Zero-copy decode — borrows directly from the input bytes
let view = DetectionFrameView::decode_view(&bytes)?;
println!("model: {}", view.model_id);  // &str, no allocation

// Convert to owned when mutation or storage is needed
let owned: DetectionFrame = view.to_owned_message();
```

Views are typically **1.5–4× faster** than owned decoding according to the project's benchmarks, because string/bytes fields become `&str`/`&[u8]` borrows into the input buffer with no allocation.

### Field type mapping in views

| Proto type       | Owned struct type          | View type                            |
|------------------|----------------------------|--------------------------------------|
| `string`         | `String`                   | `&'a str`                            |
| `bytes`          | `Vec<u8>`                  | `&'a [u8]`                           |
| scalar (int, etc)| `i32`, `f32`, etc.         | same (decoded by value)              |
| `message Foo`    | `MessageField<Foo>`        | `MessageFieldView<FooView<'a>>`      |
| `repeated T`     | `Vec<T>`                   | `RepeatedView<'a, T>`                |
| `map<K, V>`      | `HashMap<K, V>`            | `MapView<'a, K, V>` (linear scan)    |
| enum (open)      | `EnumValue<E>`             | `EnumValue<E>`                       |

`MapView` stores entries as a flat `Vec` and does **O(n) linear lookup** — fine for typical small protobuf maps but not for large indices. For larger maps: `let m: HashMap<_,_> = view.labels.into_iter().collect();`.

### `OwnedView<V>` — views with `'static` lifetime

The `'a` lifetime on `FooView<'a>` ties it to the input buffer, which prevents use across `.await` points or anywhere requiring `'static + Send`. `OwnedView<V>` solves this by co-storing the `bytes::Bytes` buffer alongside the decoded view:

```rust
use buffa::view::OwnedView;

let bytes: bytes::Bytes = receive_body().await;
let view = OwnedView::<DetectionFrameView>::decode(bytes)?;

// Deref gives direct field access
println!("{}", view.model_id);

// Clone is O(1) — Bytes refcount bump
let cloned = view.clone();
```

`OwnedView` is `Send + Sync + 'static` when the view type is — which generated views are automatically (their borrowed fields become `&'static str` / `&'static [u8]`).

### DecodeOptions with views

```rust
let view = DecodeOptions::new()
    .with_recursion_limit(20)
    .decode_view::<DetectionFrameView>(&bytes)?;

// Or with OwnedView:
let view = OwnedView::<DetectionFrameView>::decode_with_options(
    bytes,
    &DecodeOptions::new().with_max_message_size(64_000),
)?;
```

---

## Relevance to Your Cat Laser Architecture

For the Luckfox ↔ RP2040 communication you're using a packed 8-byte UART struct, so buffa isn't in the servo control loop. Where buffa fits is on the **Luckfox networking side** — if you're sending detection results, video metadata, or config updates over WiFi to a companion app or dashboard:

- **`DetectionFrameView`** on the receiving end avoids per-frame heap allocations when processing incoming detection data. On a Cortex-A7 with limited memory bandwidth, the zero-copy path matters.
- **`no_std` + `alloc`** support means buffa could theoretically run on the RP2040 side too, though your 8-byte packed UART struct is simpler and more appropriate for that link.
- **`preserve_unknown_fields(false)`** is worth setting for any messages on the embedded side to trim struct size.
- **`DecodeOptions`** with tight `max_message_size` limits should be set for any network-facing decode paths on the Luckfox, since it's a safety-critical system and malformed/oversized messages shouldn't cause OOM.

---

## Quick Reference

```toml
# Cargo.toml
[dependencies]
buffa = "0.2"
buffa-types = "0.2"       # only if using well-known types

[build-dependencies]
buffa-build = "0.2"
```

**Traits:** `buffa::Message` (owned encode/decode), `buffa::MessageView` (zero-copy decode).

**Key types:** `MessageField<T>`, `EnumValue<E>`, `RepeatedView<'a, T>`, `MapView<'a, K, V>`, `OwnedView<V>`, `DecodeOptions`, `UnknownFields`.
