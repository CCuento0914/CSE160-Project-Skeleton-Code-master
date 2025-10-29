configuration IPC {
  provides interface IP;
  uses interface LinkState;
}
implementation {
  components IPP;
  IP = IPP;

  IPP.LinkState = LinkState;

  components new SimpleSendC(AM_PACK) as IPSend;
  IPP.Sender -> IPSend;
}
