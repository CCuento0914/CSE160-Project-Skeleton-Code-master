#include <Timer.h>
#include "../../includes/packet.h"
#include "../../includes/channels.h"
#include <string.h>

module NeighborDiscoverP {
    provides interface NeighborDiscover;
    uses interface Timer<TMilli> as neighborTimer;
    uses interface SimpleSend as Sender;
}

implementation {
    #define TIMEOUT_MS 5000
    typedef struct { uint16_t id; uint32_t lastSeen; bool used; } neigh_t;
    neigh_t table[16]; 

    void Note(uint16_t id, uint32_t now) {
        int i, freeIdx;
        freeIdx = -1;
        for (i = 0; i < 16; i++) {
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
        call neighborTimer.startPeriodic(700);
  }

  command void NeighborDiscover.printNeighbors() {
    int i;
    dbg(NEIGHBOR_CHANNEL, "NEIGHBORS %u: [", TOS_NODE_ID);
    for (i = 0; i < 16; i++) {
      if (table[i].used) { dbg_clear(NEIGHBOR_CHANNEL, " %u", table[i].id); }
    }
    dbg_clear(NEIGHBOR_CHANNEL, " ]\n");
  }

  command void NeighborDiscover.Receive(uint16_t src) {
    uint32_t now;
    now = (uint32_t)call neighborTimer.getNow();
    Note(src, now);
  }
 
  event void neighborTimer.fired() {
    uint32_t now;
    int i;
    pack p;

    now = (uint32_t)call neighborTimer.getNow();

    for (i = 0; i < 16; i++) {
      if (table[i].used && (now - table[i].lastSeen) > TIMEOUT_MS) {
        dbg(NEIGHBOR_CHANNEL, "NEIGHBOR: drop %u\n", table[i].id);
        table[i].used = FALSE;
      }
    }

    memset(&p, 0, sizeof(pack));
    p.src = TOS_NODE_ID; p.dest = AM_BROADCAST_ADDR; p.TTL = 1;
    p.seq = (uint16_t)((TOS_NODE_ID << 1) ^ 0xAA); p.protocol = 0;
    p.payload[0] = 1;
    dbg(NEIGHBOR_CHANNEL, "NEIGHBOR: beacon from %u\n", TOS_NODE_ID);
    call Sender.send(p, AM_BROADCAST_ADDR);
  }
}
