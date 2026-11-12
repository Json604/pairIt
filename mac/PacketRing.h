#include <stdint.h>
typedef struct ARPacketRing ARPacketRing;
ARPacketRing *ARCreate(void);
void ARDestroy(ARPacketRing *ring);
uint8_t *ARWriteSlot(ARPacketRing *ring);
void ARCommit(ARPacketRing *ring, uint32_t length);
const uint8_t *ARReadSlot(ARPacketRing *ring, uint32_t *length);
void ARConsume(ARPacketRing *ring);
uint64_t ARDrops(ARPacketRing *ring);
