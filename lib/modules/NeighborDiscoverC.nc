#include "../../includes/am_types.h"

generic configuration NeighborDiscoverC(int channel){
    provides interface NeighborDiscover;
}

implementation{
    components new NeighborDiscoverP();
    NeighborDiscover = NeighborDiscoverP.NeighborDiscover;

   components new TimerMilliC() as sendTimer;
   components RandomC as Random;
   components new SimpleSendC(AM_PACK);
   
   NeighborDiscoverP.SimpleSend -> SimpleSendC;
   NeighborDiscoverP.sendTimer -> sendTimer;
   NeighborDiscoverP.Random -> Random;
    
}