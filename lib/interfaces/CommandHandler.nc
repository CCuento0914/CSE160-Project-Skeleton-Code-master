interface CommandHandler{
   // Events
   event void ping(uint16_t destination, uint8_t *payload);
   event void printNeighbors();
   event void printRouteTable();
   event void printLinkState();
   event void printDistanceVector();
   event void setTestServer(uint8_t serverPort);
   event void setTestClient(uint8_t serverNode,
                           uint8_t clientSrcPort,
                           uint8_t serverPort,
                           uint8_t transferCount);
   event void chatStartServer();
   event void chatStopServer();
   event void chatHello(uint8_t *payload);
   event void chatMsg(uint8_t *payload);
   event void chatWhisper(uint8_t *payload);
   event void chatListUsr();
   event void setAppServer();
   event void setAppClient();
}
