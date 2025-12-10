interface ChatServer {
  command void start(uint8_t port);
  command void stop();
  command void chatHello(uint8_t *payload);
  command void chatMsg(uint8_t *payload);
  command void chatWhisper(uint8_t *payload);
  command void chatListUsr();
}
