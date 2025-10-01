#include "../../includes/packet.h"
#include "../../includes/channels.h"
#include <string.h>

module FloodingP {
  provides interface Flooding;
  uses interface SimpleSend as Sender;
}
implementation {
    // Small seen-cache to prevent infinite rebroadcast loops.
    #define SEEN_CACHE_SIZE 16
    typedef struct {uint16_t src; uint16_t seq; bool used;} seen_t;
    seen_t seen[SEEN_CACHE_SIZE];
    uint8_t seen_idx = 0;

    bool seen_before(uint16_t src, uint16_t seq) {
        int i;
        for (i = 0; i < SEEN_CACHE_SIZE; i++) {
            if (seen[i].used && seen[i].src == src && seen[i].seq == seq) return TRUE;
    }
    return FALSE;
    }

    void mark_seen(uint16_t src, uint16_t seq) {
        seen[seen_idx].used = TRUE;
        seen[seen_idx].src = src;
        seen[seen_idx].seq = seq;
        seen_idx = (seen_idx + 1) % SEEN_CACHE_SIZE;
    }

    command void Flooding.FloodTest() {
        pack p; 
        const char *msg; 

        memset(&p, 0, sizeof(pack));
        p.src = TOS_NODE_ID;
        p.dest = AM_BROADCAST_ADDR; 
        p.TTL = 3; // Limit to 3 hops
        p.seq = (uint16_t)((TOS_NODE_ID << 8) ^ 0x55); // Simple unique-ish seq no.
        p.protocol = 0; 

        msg = "flood";
        memcpy(p.payload, msg, 6);

        dbg(FLOODING_CHANNEL, "FLOODTEST: node %u\n", TOS_NODE_ID);
        call Sender.send(p, AM_BROADCAST_ADDR);
        mark_seen(p.src, p.seq);
        }

    command void Flooding.handleReceive(pack *msg) {
        pack fwd; 
        if (seen_before(msg->src, msg->seq)) {
            dbg(FLOODING_CHANNEL, "FLOOD: drop (seen src=%u seq=%u)\n", msg->src, msg->seq);
            return;
        }
        mark_seen(msg->src, msg->seq);

        dbg(FLOODING_CHANNEL, "FLOOD: rcvd src=%u dest=%u ttl=%u seq=%u\n",
            msg->src, msg->dest, msg->TTL, msg->seq);
        
        if (msg->dest != TOS_NODE_ID && msg->TTL > 0) {
            fwd = *msg;
            fwd.TTL -= 1;
            dbg(FLOODING_CHANNEL, "FLOOD: fwd src=%u dest=%u ttl=%u\n",
                fwd.src, fwd.dest, fwd.TTL); 
            call Sender.send(fwd, AM_BROADCAST_ADDR);
        }
    }
}
