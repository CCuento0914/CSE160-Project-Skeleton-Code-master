#include <Timer.h>

generic module NeighborDiscoveryP(){
    provides interface NeighborDiscovery;

    uses interface Timer<TMilli> as neighborTimer;
    uses interface Random;
}

implementation {

    command void NeighborDiscovery.findNeighbors(){
        call neighborTimer.startOneShot(100+ (call Random.rand16() %300));
    }

    task void search(){
        "logic: send the msg, if somebody responds, save its ID inside table"
    }

    event void sendTimer.fired(){
        post sendBufferTask();
   }
    command void NeighborDiscovery.printNeightbors();

}