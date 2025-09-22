#include <Timer.h>

generic module NeighborDiscoveryP(){
    provides interface NeighborDiscovery;

    uses interface Timer<TMilli> as neighborTimer;
    uses interface Random;
    uses interface SimpleSend;
}

implementation {
    pack* sendID;

    command void NeighborDiscovery.findNeighbors(auto &pack) {
        call neighborTimer.startOneShot(100+ (call Random.rand16() %300));
        sendID = &pack;
    }

    task void search() {
        "logic: send the msg, if somebody responds, save its id inside table"
        call neighborTimer.startPeriodic(100+ (call Random.rand16() %300));
        call SimpleSend.send(sendID, AM_BROADCAST_ADDR);
    }

    event void sendTimer.fired() {
        post search();
    }

    command void NeighborDiscovery.printNeighbors() {
        
    }
}