generic configuration FloodingC(int channel){
    provides interface Flooding;
}

implementation {
    components new FloodingP();
    Flooding = FloodingP.Flooding;
}