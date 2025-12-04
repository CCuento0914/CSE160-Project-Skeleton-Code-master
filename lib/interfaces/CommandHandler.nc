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
   event void setAppServer();
   event void setAppClient();
}
