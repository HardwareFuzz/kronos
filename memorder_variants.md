# Memorder variants (current direction)

This file documents memory-ordering variants for Kronos testing.

Use: ./build.sh --memorder <id>
Use: ./memorder_variants.sh

Variant ids:
- default      : no store buffer (baseline ordering)
- sb           : 1-entry store buffer, loads stall while buffer valid, fence drains
- sb-bypass    : 1-entry store buffer, loads may bypass unless same-word conflict
- sb-fence-nop : 1-entry store buffer, fence does not drain the buffer

Notes:
- The buffer is single-entry; stores are enqueued when empty and drained in the background.
- Load bypass is controlled by STBUF_ALLOW_LOAD_BYPASS and STBUF_CONFLICT_STALL.
- FENCE handling is controlled by FENCE_DRAIN_STBUF.
