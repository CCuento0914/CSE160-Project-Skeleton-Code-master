#include "../../includes/packet.h"
#include "../../includes/channels.h"
#include "../../includes/protocol.h"
#include <string.h>

module IPP {
  provides interface IP;
  uses interface LinkState;
  uses interface SimpleSend as Sender;
}
implementation {
  command void IP.forward(pack *p) {
    int16_t nh;

    if (p->dest == TOS_NODE_ID || p->dest == AM_BROADCAST_ADDR) return;
    if (p->protocol == PROTOCOL_FLOOD || p->protocol == PROTOCOL_LINKSTATE) return;

    nh = call LinkState.nextHop(p->dest);
    if (nh >= 0) {
      if (p->TTL == 0) return;
      p->TTL -= 1;
      if (p->TTL == 0) return;
      call Sender.send(*p, (uint16_t)nh);
      dbg(ROUTING_CHANNEL, "IP: forward to %u via %u\n", p->dest, (uint16_t)nh);
    } else {
      dbg(ROUTING_CHANNEL, "IP: no route to %u\n", p->dest);
    }
  }
}
