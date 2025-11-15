#include "../../includes/channels.h"

configuration TransportC {
  provides interface Transport;
}
implementation {
  components TransportP;
  Transport = TransportP.Transport;

  components new SimpleSendC(AM_PACK);
  TransportP.Sender -> SimpleSendC;

  components LinkStateC;
  TransportP.LinkState -> LinkStateC;

  components IPC;
  TransportP.IP -> IPC;

  //TransportP.retransTimer -> TimerC;
}
