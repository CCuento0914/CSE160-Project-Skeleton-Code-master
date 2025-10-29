generic configuration FloodingC(am_id_t channel) {
  provides interface Flooding;
}
implementation {
  components FloodingP;
  Flooding = FloodingP;

  components new SimpleSendC(channel) as SSC;
  FloodingP.Sender -> SSC;

  components new TimerMilliC() as FT;
  FloodingP.retryTimer -> FT;
}
