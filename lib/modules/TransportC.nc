configuration TransportC {
  provides interface Transport;
  uses interface IP; 
}
implementation {
  components TransportP;
  Transport = TransportP.Transport;
  TransportP.IP = IP;

  components new TimerMilliC() as TimerC;
  TransportP.retransTimer -> TimerC;
}
