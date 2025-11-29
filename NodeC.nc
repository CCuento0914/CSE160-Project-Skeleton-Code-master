/**
 * ANDES Lab - University of California, Merced
 * This class provides the basic functions of a network node.
 *
 * @author UCM ANDES Lab
 * @date   2013/09/03
 *
 */

#include <Timer.h>
#include "includes/CommandMsg.h"
#include "includes/packet.h"

configuration NodeC{
}
implementation {
    components MainC;
    components Node;
    components new AMReceiverC(AM_PACK) as GeneralReceive;

    Node -> MainC.Boot;

    Node.Receive -> GeneralReceive;

    components ActiveMessageC;
    Node.AMControl -> ActiveMessageC;

    components new SimpleSendC(AM_PACK);
    Node.Sender -> SimpleSendC;

    components CommandHandlerC;
    Node.CommandHandler -> CommandHandlerC;

    components new FloodingC(AM_PACK);
    Node.Flooding -> FloodingC;

    components new NeighborDiscoverC(AM_PACK);
    Node.NeighborDiscover -> NeighborDiscoverC;

    components LinkStateC;
    Node.LinkState -> LinkStateC;

    NeighborDiscoverC.LinkState -> LinkStateC;
    LinkStateC.NeighborDiscover -> NeighborDiscoverC;
    LinkStateC.Flooding -> FloodingC;

    components IPC;
    Node.IP -> IPC;
    IPC.LinkState -> LinkStateC;

    components TransportC;
    Node.Transport -> TransportC;

    components new TimerMilliC() as ServerTimerC;
    Node.ServerTimer -> ServerTimerC;

    components new TimerMilliC() as ClientTimerC;
    Node.ClientTimer -> ClientTimerC;
}
