#include <Timer.h>
#include "../../includes/packet.h"
#include "../../includes/channels.h"
#include "../../includes/protocol.h"
#include <string.h>

module NeighborDiscoverP {
  provides interface NeighborDiscover;
  uses interface Timer<TMilli> as neighborTimer;
  uses interface SimpleSend as Sender;
  uses interface LinkState;
}
implementation {
  #define TIMEOUT_MS 12000
  #define NBR_CAP 16

  typedef struct { uint16_t id; uint32_t lastSeen; bool used; } neigh_t;
  neigh_t table[NBR_CAP];

  void note(uint16_t id, uint32_t now) {
    int i, freeIdx = -1;
    if (id == TOS_NODE_ID) return;

    for (i = 0; i < NBR_CAP; i++) {
      if (table[i].used && table[i].id == id) {
        table[i].lastSeen = now;
        return;
      }
      if (!table[i].used && freeIdx == -1) freeIdx = i;
    }
    if (freeIdx != -1) {
      table[freeIdx].used = TRUE;
      table[freeIdx].id = id;
      table[freeIdx].lastSeen = now;
      dbg(NEIGHBOR_CHANNEL, "NEIGHBOR: add %u\n", id);
    }
  }

  command void NeighborDiscover.findNeighbors() {
    call neighborTimer.startPeriodic(1500);
  }

  command void NeighborDiscover.printNeighbors() {
    int i;
    dbg(NEIGHBOR_CHANNEL, "NEIGHBORS %u: [", TOS_NODE_ID);
    for (i = 0; i < NBR_CAP; i++) {
      if (table[i].used) { dbg_clear(NEIGHBOR_CHANNEL, " %u", table[i].id); }
    }
    dbg_clear(NEIGHBOR_CHANNEL, " ]\n");
  }

  command void NeighborDiscover.Receive(uint16_t src) {
    uint32_t now = (uint32_t) call neighborTimer.getNow();
    note(src, now);
    call LinkState.noteNeighborChange();
  }

  event void neighborTimer.fired() {
    uint32_t now = (uint32_t) call neighborTimer.getNow();
    int i;
    pack p;

    // Expire stale neighbors
    for (i = 0; i < NBR_CAP; i++) {
      if (table[i].used && (now - table[i].lastSeen) > TIMEOUT_MS) {
        dbg(NEIGHBOR_CHANNEL, "NEIGHBOR: drop %u\n", table[i].id);
        table[i].used = FALSE;
        call LinkState.noteNeighborChange();
      }
    }

    // Send a small beacon
    memset(&p, 0, sizeof(pack));
    p.src = TOS_NODE_ID;
    p.dest = AM_BROADCAST_ADDR;
    p.TTL = 1;
    p.seq = (uint16_t)((TOS_NODE_ID << 1) ^ 0xAA);
    p.protocol = PROTOCOL_BEACON;
    p.payload[0] = 1;

    call Sender.send(p, AM_BROADCAST_ADDR);
  }
  command uint8_t NeighborDiscover.snapshot(uint16_t *out, uint8_t maxn) {
    uint8_t i, k=0;
    for (i=0;i<NBR_CAP && k<maxn;i++) {
      if (table[i].used) { out[k++] = table[i].id; }
    }
    return k;
  }
}
