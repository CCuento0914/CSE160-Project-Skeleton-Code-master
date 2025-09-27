#include <Timer.h>

generic module FloodingP(int channel) {
    provides interface Flooding;

    uses interface Timer<TMilli> as floodTimer;
    uses interface Random;
    uses interface SimpleSend;
}

implementation {
    pack* currentPack
}