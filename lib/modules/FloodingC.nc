generic configuration FloodingC(am_id_t AMID) {
  provides interface Flooding;
}
implementation {
  components FloodingP;
  components new SimpleSendC(AMID) as SSC;

  Flooding = FloodingP;
  FloodingP.Sender -> SSC;
}
