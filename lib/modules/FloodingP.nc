#include <Timer.h>

generic module FloodingP() {
    provides interface Flooding;

    uses interface Timer<TMilli> as floodTimer;
    uses interface Random;
    uses interface SimpleSend;
}