#include "../../includes/packet.h"
#include "../../includes/channels.h"
#include "../../includes/protocol.h"
#include <string.h>

module FloodingP {
  provides interface Flooding;
  uses interface SimpleSend as Sender;
  uses interface Timer<TMilli> as retryTimer; 
}
implementation {
  // Cache of seen (src,seq) pairs to avoid rebroadcasting duplicates
  #define SEEN_CACHE_SIZE 64
  typedef struct { uint16_t src; uint16_t seq; bool used; } seen_t;
  seen_t seen[SEEN_CACHE_SIZE];
  uint8_t seen_idx = 0;

  bool havePending = FALSE;
  pack pending;
  uint8_t retryCount = 0;
  #define MAX_RETRIES 10

  bool seen_before(uint16_t src, uint16_t seq) {
    int i;
    for (i = 0; i < SEEN_CACHE_SIZE; i++) {
      if (seen[i].used && seen[i].src == src && seen[i].seq == seq) return TRUE;
    }
    return FALSE;
  }

  void mark_seen(uint16_t src, uint16_t seq) {
    seen[seen_idx].used = TRUE;
    seen[seen_idx].src  = src;
    seen[seen_idx].seq  = seq;
    seen_idx = (seen_idx + 1) % SEEN_CACHE_SIZE;
  }

  void queue_retry(pack *p) {
    pending = *p;
    havePending = TRUE;
    if (retryCount < MAX_RETRIES) retryCount++;
    call retryTimer.startOneShot(5 * retryCount);
  }

  void try_send(pack *p, bool is_first) {
    error_t e = call Sender.send(*p, AM_BROADCAST_ADDR);
    if (e == SUCCESS) {
      /*dbg(FLOODING_CHANNEL, "FLOOD: %s src=%u seq=%u ttl=%u -> broadcast OK\n",
          (is_first ? "start" : "fwd"), p->src, p->seq, p->TTL);*/
      havePending = FALSE;
      retryCount = 0;
    } else {
      /*dbg(FLOODING_CHANNEL, "FLOOD: send EBUSY (src=%u seq=%u ttl=%u), retrying...\n",
          p->src, p->seq, p->TTL);*/
      queue_retry(p);
    }
  }

  command void Flooding.handleReceive(pack *msg) {
    pack fwd;

    // Log entry so we can see the call even if we don't end up sending
    /*dbg(FLOODING_CHANNEL, "FLOOD: handleReceive at %u src=%u seq=%u ttl=%u dest=%u proto=%u\n",
        TOS_NODE_ID, msg->src, msg->seq, msg->TTL, msg->dest, msg->protocol);*/

    // Never flood beacons
    if (msg->protocol == PROTOCOL_BEACON) return;

    // Drop duplicates
    if (seen_before(msg->src, msg->seq)) {
      //dbg(FLOODING_CHANNEL, "FLOOD: drop duplicate src=%u seq=%u\n", msg->src, msg->seq);
      return;
    }
    mark_seen(msg->src, msg->seq);

    // If I'm the destination, deliver (no re-broadcast)
    if (msg->dest == TOS_NODE_ID) {
        dbg(FLOODING_CHANNEL, "node %u got '%s' from %u\n",
        TOS_NODE_ID, msg->payload, msg->src);
        return;
    }

    // Decrement TTL and forward if still positive
    if (msg->TTL == 0) return;
    fwd = *msg;
    fwd.TTL -= 1;
    if (fwd.TTL == 0) return;

    try_send(&fwd, /*is_first=*/FALSE);
  }

  event void retryTimer.fired() {
    if (!havePending) return;
    if (pending.TTL == 0) { havePending = FALSE; retryCount = 0; return; }
    try_send(&pending, /*is_first=*/FALSE);
  }
}
