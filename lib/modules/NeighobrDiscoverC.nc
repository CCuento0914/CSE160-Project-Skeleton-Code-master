#include "../../includes/am_types.h"

generic module NeighborDiscoveryC(int channel){
    provides interface NeighborDiscovery;
}

implementation{
    components new NeighborDiscoverP();
    NeighborDiscover = NeighborDiscoverP.NeighborDiscover;

   components new TimerMilliC() as sendTimer;
   components RandomC as Random;
   components new AMSenderC(channel);

   //Timers
   NeighborDiscoverP.sendTimer -> sendTimer;
   NeighborDiscoverP.Random -> Random;

   NeighborDiscoverP.Packet -> AMSenderC;
   NeighborDiscoverP.AMPacket -> AMSenderC;
   NeighborDiscoverP.AMSend -> AMSenderC;

   //Lists
   components new PoolC(sendInfo, 20);
   components new QueueC(sendInfo*, 20);

   NeighborDiscoverP.Pool -> PoolC;
   NeighborDiscoverP.Queue -> QueueC;
    
}