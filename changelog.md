# Changelog

## 5.17.0 - 2026-02

### Added
- Added `proxy_protocol = auto` support for both `gen_tcp` and socket listeners.
- Added conditional `wait/1` prefetched return support for auto-upgrade flows.

### Changed
- Enforced `proxy_protocol = auto` only when `{packet, raw}` is used.
- Made partial PROXY protocol v2 signature upgrade failures fail fast with meaningful reasons (`proxy_proto_timeout`, `proxy_proto_close`) returned to applications.


