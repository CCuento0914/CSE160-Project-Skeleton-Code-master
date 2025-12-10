configuration ChatServerC {
  provides interface ChatServer;
  uses interface Transport;
}
implementation {
  components ChatServerP;
  ChatServer = ChatServerP;

  ChatServerP.Transport = Transport;

  components new TimerMilliC() as ChatTimerC;
  ChatServerP.ChatTimer -> ChatTimerC;
}
