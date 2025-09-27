#include <Timer.h>

generic module FloodingP() {
    provides interface Flooding;
}

implementation {
    command void Flooding.FloodTest(){
        dbg(GENERAL_CHANNEL,"Flood dbg");
    }
}