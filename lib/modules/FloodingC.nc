generic module FloodingC(int channel){
    provides interface Flooding;
}

implementation {
    components FloodingP;
    components new TimerMilliC as FloodTimer;
    components new RandomMlcgC as FloodRandom;
    components new SimpleSendC as FloodSimpleSend;

    Flooding = FloodingP;
    connect FloodingP.floodTimer -> FloodTimer;
    connect FloodingP.Random -> FloodRandom;
    connect FloodingP.SimpleSend -> FloodSimpleSend;
}