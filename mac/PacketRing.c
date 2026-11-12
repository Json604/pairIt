#include "PacketRing.h"
#include <stdatomic.h>
#include <stdlib.h>
#define CAPACITY 32
#define MAX_PACKET (24 + 8192 * 4)
struct ARSlot { uint32_t length; _Alignas(8) uint8_t bytes[MAX_PACKET]; };
struct ARPacketRing {
    _Atomic uint32_t head;
    _Atomic uint32_t tail;
    _Atomic uint64_t drops;
    struct ARSlot slots[CAPACITY];
};
ARPacketRing *ARCreate(void) {
    ARPacketRing *r = calloc(1, sizeof(ARPacketRing));
    if (r) { atomic_init(&r->head, 0); atomic_init(&r->tail, 0); atomic_init(&r->drops, 0); }
    return r;
}
void ARDestroy(ARPacketRing *r) { free(r); }
uint8_t *ARWriteSlot(ARPacketRing *r) {
    uint32_t h = atomic_load_explicit(&r->head, memory_order_relaxed);
    uint32_t t = atomic_load_explicit(&r->tail, memory_order_acquire);
    if (h - t >= CAPACITY) { atomic_fetch_add(&r->drops, 1); return NULL; }
    return r->slots[h % CAPACITY].bytes;
}
void ARCommit(ARPacketRing *r, uint32_t length) {
    uint32_t h = atomic_load_explicit(&r->head, memory_order_relaxed);
    r->slots[h % CAPACITY].length = length;
    atomic_store_explicit(&r->head, h + 1, memory_order_release);
}
const uint8_t *ARReadSlot(ARPacketRing *r, uint32_t *length) {
    uint32_t t = atomic_load_explicit(&r->tail, memory_order_relaxed);
    uint32_t h = atomic_load_explicit(&r->head, memory_order_acquire);
    if (t == h) return NULL;
    *length = r->slots[t % CAPACITY].length;
    return r->slots[t % CAPACITY].bytes;
}
void ARConsume(ARPacketRing *r) { atomic_fetch_add_explicit(&r->tail, 1, memory_order_release); }
uint64_t ARDrops(ARPacketRing *r) { return atomic_load(&r->drops); }
