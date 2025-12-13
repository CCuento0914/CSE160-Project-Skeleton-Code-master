configuration ChatClientC {
  provides interface ChatClient;
  uses interface Transport;
}
implementation {
  components ChatClientP;
  ChatClient = ChatClientP;

  ChatClientP.Transport = Transport;

  components new TimerMilliC() as ChatClientTimerC;
  ChatClientP.ChatClientTimer -> ChatClientTimerC;
}
