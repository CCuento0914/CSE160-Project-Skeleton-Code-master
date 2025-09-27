#include <Timer.h>

generic module NeighborDiscoverP(){
    provides interface NeighborDiscover;

    uses interface Timer<TMilli> as sendTimer;
    uses interface Random;
    uses interface SimpleSend;
}

implementation {
    pack sendID;

    command void NeighborDiscover.findNeighbors() {
        // call neighborTimer.startOneShot(100+ (call Random.rand16() %300));
        dbg(GENERAL_CHANNEL,"NeighborDisc dbg");
    }

    task void search() {
        // "logic: send the msg, if somebody responds, save its id inside table"
        call sendTimer.startPeriodic(100+ (call Random.rand16() %300));
        call SimpleSend.send(sendID, AM_BROADCAST_ADDR);
    }

    event void sendTimer.fired() {
        post search();
    }

    command void NeighborDiscover.printNeighbors() {
        
    }
    
}