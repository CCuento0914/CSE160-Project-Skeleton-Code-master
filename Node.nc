/*
 * ANDES Lab - University of California, Merced
 * This class provides the basic functions of a network node.
 *
 * @author UCM ANDES Lab
 * @date   2013/09/03
 *
 */

#include <Timer.h>
#include <string.h>
#include <stdint.h>
#include "includes/socket.h"
#include "includes/command.h"
#include "includes/packet.h"
#include "includes/protocol.h"
#include "includes/CommandMsg.h"
#include "includes/sendInfo.h"
#include "includes/channels.h"

module Node{
   uses interface Boot;

   uses interface SplitControl as AMControl;
   uses interface Receive;

   uses interface SimpleSend as Sender;

   uses interface CommandHandler;
   uses interface Flooding;
   uses interface NeighborDiscover;
   uses interface LinkState;
   uses interface IP;
   uses interface Transport;
   uses interface ChatServer;
   uses interface Timer<TMilli> as ServerTimer;
   uses interface Timer<TMilli> as ClientTimer;
}

implementation{
   pack sendPackage;
   uint16_t floodSeq = 1;
   uint16_t pingSeq  = 0;
   socket_t serverListenFd = 255; 
   socket_t serverClients[MAX_NUM_OF_SOCKETS];
   uint8_t serverClientCount = 0;
   socket_t  clientFd = 255;
   socket_addr_t clientServerAddr;
   bool clientActive = FALSE;
   uint8_t cmdServerPort = 80; 
   uint16_t cmdClientDest = 4;
   uint8_t cmdClientSrcPort = 40;
   uint8_t cmdClientDestPort = 80;
   uint16_t cmdClientTransfer = 50;

   // we’ll send a sequence of uint16_t values 0..clientTransferMax
   uint16_t clientTransferMax = 0;
   uint16_t clientNextValue = 0;
   uint16_t clientValuesLeft = 0;

   socket_t testServerFd = 255;
   socket_t testClientFd = 255;

   socket_t appClientFd = 255;
   socket_addr_t appServerAddr;

   void makePack(pack *Package, uint16_t src, uint16_t dest, uint16_t TTL,
                 uint16_t protocol, uint16_t seq, uint8_t *payload, uint8_t length);

   static void forward_by_ls(pack *p) {
      int16_t nh;
      if (p->TTL == 0) return;
      p->TTL--;

      nh = call LinkState.nextHop(p->dest);
      if (nh > 0) {
         call IP.forward(p);
      } else {
         dbg(GENERAL_CHANNEL, "FORWARD: no route (nh=%d), trying direct to %u\n", nh, p->dest);
         call IP.forward(p);
      }
   }

   static void sendPingTo(uint16_t dest, const uint8_t *payload) {
      pack pkt;
      uint16_t L; 
      uint16_t n;
      int16_t nh;

      memset(&pkt, 0, sizeof(pack));
      pkt.src = TOS_NODE_ID;
      pkt.dest = dest; 
      pkt.TTL = 30;
      pkt.seq = ++pingSeq;
      pkt.protocol = PROTOCOL_PING;

      n = 0;
      if (payload) {
         const char *s = (const char*)payload;
         L = 0;
         while (s[L] != '\0' && L < PACKET_MAX_PAYLOAD_SIZE) L++;
         n = (L < PACKET_MAX_PAYLOAD_SIZE) ? (L + 1) : L;
         memcpy(pkt.payload, payload, n);
      }

      nh = call LinkState.nextHop(pkt.dest);
      if (nh > 0) { 
         dbg(ROUTING_CHANNEL, "PING: sending to %u via %d\n", pkt.dest, nh);
         call IP.forward(&pkt);
      } else {
         dbg(ROUTING_CHANNEL, "PING: no route to %u (nh=%d), trying direct\n", pkt.dest, nh);
         call IP.forward(&pkt);
      }
   }

   event void ServerTimer.fired() {
     socket_t newFd;
     uint8_t i;
     uint16_t n;
     uint8_t buf[64];
     bool already = FALSE;

     if (serverListenFd == 255) {
       // server not running
       return;
     }

     for (i = 0; i < serverClientCount; i++) {
       if (serverClients[i] == newFd) {
         already = TRUE;
         break;
       }
     }
     if (!already && serverClientCount < MAX_NUM_OF_SOCKETS) {
       serverClients[serverClientCount++] = newFd;
       dbg(TRANSPORT_CHANNEL,
           "Server accepted new connection: fd=%u\n", newFd);
     }


     // Try to accept a new connection
     newFd = call Transport.accept(serverListenFd);
     if (newFd != 255) {
       if (serverClientCount < MAX_NUM_OF_SOCKETS) {
         serverClients[serverClientCount++] = newFd;
         dbg(TRANSPORT_CHANNEL,
             "Server accepted new connection: fd=%u\n", newFd);
       } else {
         dbg(TRANSPORT_CHANNEL,
             "Server: too many clients, closing fd=%u\n", newFd);
         call Transport.close(newFd);
       }
     }

     // For all accepted sockets: read data and print
     for (i = 0; i < serverClientCount; i++) {
       socket_t fd = serverClients[i];
       n = call Transport.read(fd, buf, sizeof(buf));
       if (n > 0) {
         uint16_t j;
         dbg(TRANSPORT_CHANNEL,
             "Server read %u bytes from fd=%u: ", n, fd);
         for (j = 0; j < n; j++) {
           dbg(TRANSPORT_CHANNEL, "%02x ", buf[j]);
         }
         dbg(TRANSPORT_CHANNEL, "\n");
       }
     }
   }

   event void ClientTimer.fired() {
     uint8_t buf[64];       // send buffer
     uint16_t maxVals;      // how many uint16s fit in buf
     uint16_t valsToSend;
     uint16_t i;
     uint16_t bytesToSend;
     uint16_t bytesWritten;

     if (!clientActive || clientFd == 255) {
       return;
     }

     // If nothing left to send, stop the timer and optionally close
     if (clientValuesLeft == 0) {
       dbg(TRANSPORT_CHANNEL, "Client: all data sent, stopping timer\n");
       call ClientTimer.stop();
       call Transport.close(clientFd);
       clientActive = FALSE;
       return;
     }

     // each uint16_t takes 2 bytes
     maxVals = sizeof(buf) / 2;
     valsToSend = clientValuesLeft;
     if (valsToSend > maxVals) valsToSend = maxVals;

     // Fill buf with valsToSend 16-bit values starting at clientNextValue
     for (i = 0; i < valsToSend; i++) {
       uint16_t v = clientNextValue + i;
       buf[2*i] = (uint8_t)(v >> 8);
       buf[2*i+1] = (uint8_t)(v & 0xFF); 
     }

     bytesToSend = (uint16_t)(valsToSend * 2);

     bytesWritten = call Transport.write(clientFd, buf, bytesToSend);
     if (bytesWritten == 0) {
       // send buffer/window full or connection not yet ESTABLISHED;
       // we’ll try again on the next timer.
       // dbg(TRANSPORT_CHANNEL, "Client: write() returned 0, retry later\n"); commented out to reduce log spam
       return;
     }

     // subtract the amount of data you were able to write(fd, buffer, buffer len)
     {
       uint16_t valsWritten = bytesWritten / 2;
       if (valsWritten > clientValuesLeft) valsWritten = clientValuesLeft;

       clientValuesLeft -= valsWritten;
       clientNextValue  += valsWritten;

       dbg(TRANSPORT_CHANNEL,
           "Client: wrote %u bytes (%u values), nextValue=%u, left=%u\n",
           bytesWritten, valsWritten, clientNextValue, clientValuesLeft);
     }
   }

   event void Boot.booted(){
      uint8_t i;
      serverListenFd = 255;
      serverClientCount = 0;
      call AMControl.start();
      for (i = 0; i < MAX_NUM_OF_SOCKETS; i++) {
          serverClients[i] = 255;
      }
      dbg(GENERAL_CHANNEL, "Booted\n");
   }

   event void AMControl.startDone(error_t err){
      if(err == SUCCESS){
         dbg(GENERAL_CHANNEL, "Radio On\n");
         call NeighborDiscover.findNeighbors();
      }else{
         call AMControl.start();
      }
   }

   event void AMControl.stopDone(error_t err){}

   event message_t* Receive.receive(message_t* msg, void* payload, uint8_t len) {
      if (len == sizeof(pack)) {
         pack* myMsg = (pack*) payload;

         switch (myMsg->protocol) {
           case PROTOCOL_FLOOD: {
             call Flooding.handleReceive(myMsg);
             dbg(FLOODING_CHANNEL, "FLOOD: recv src=%u seq=%u ttl=%u dest=%u\n",
                 myMsg->src, myMsg->seq, myMsg->TTL, myMsg->dest);
             break;
           }

           case PROTOCOL_BEACON: {
             call NeighborDiscover.Receive(myMsg->src);
             break;
           }

           case PROTOCOL_PING: {
             if (myMsg->dest == TOS_NODE_ID) {
               pack reply; 
               dbg(GENERAL_CHANNEL, "node %u got '%s' from %u\n",
                   TOS_NODE_ID, (char*)myMsg->payload, myMsg->src);

               memset(&reply, 0, sizeof(pack));
               reply.src      = TOS_NODE_ID;
               reply.dest     = myMsg->src;
               reply.TTL      = 30;
               reply.seq      = myMsg->seq; 
               reply.protocol = PROTOCOL_PINGREPLY;
               memcpy(reply.payload, myMsg->payload, PACKET_MAX_PAYLOAD_SIZE);

               forward_by_ls(&reply);
             } else {
               forward_by_ls(myMsg);
             }
             break;
           }

           case PROTOCOL_PINGREPLY: {
             if (myMsg->dest == TOS_NODE_ID) {
               dbg(GENERAL_CHANNEL, "PINGREPLY: received from %u seq=%u\n",
                   myMsg->src, myMsg->seq);
             } else {
               forward_by_ls(myMsg);
             }
             break;
           }

           case PROTOCOL_LINKSTATE: {
             call LinkState.handleLSA(myMsg);
             call Flooding.handleReceive(myMsg);
             break;
           }

           case PROTOCOL_NAME:
           case PROTOCOL_TCP: {
              if (myMsg->dest == TOS_NODE_ID) {
                // This node is the endpoint: hand to Transport
                call Transport.receive(myMsg);
              } else {
                // This node is just a router: forward via IP
                call IP.forward(myMsg);
              }
              break;
            }
           
           case PROTOCOL_DV:
           case PROTOCOL_NEIGHBOR:
           case PROTOCOL_CMD: {
             dbg(GENERAL_CHANNEL, "Unhandled (but known) protocol %d\n", myMsg->protocol);
             break;
           }

           default: {
             dbg(GENERAL_CHANNEL, "Unknown Protocol %d\n", myMsg->protocol);
             break;
           }
         }

         return msg;
      }

      dbg(GENERAL_CHANNEL, "Unknown Packet Size %d\n", len);
      return msg;
   }

   event void CommandHandler.ping(uint16_t destination, uint8_t *payload){
      dbg(GENERAL_CHANNEL, "PING EVENT \n");
      sendPingTo(destination, payload);
   }

   event void CommandHandler.printRouteTable() {
      dbg(COMMAND_CHANNEL, "PRINT ROUTETABLE EVENT\n");
      call LinkState.routeDump();
   }
   
   event void CommandHandler.printDistanceVector(){}

   event void CommandHandler.printNeighbors(){
      dbg(GENERAL_CHANNEL, "PRINT NEIGHBORS EVENT \n");
      call NeighborDiscover.printNeighbors();
   }

   event void CommandHandler.printLinkState() {
      dbg(COMMAND_CHANNEL, "PRINT LINKSTATE EVENT\n");
      call LinkState.routeDump();
   }

   event void CommandHandler.setTestServer(uint8_t serverPort) {
    socket_addr_t addr;

    dbg(TRANSPORT_CHANNEL, "TEST SERVER EVENT\n");

    // For now we just overwrite.
    serverListenFd = call Transport.socket();
    if (serverListenFd == 255) {
      dbg(TRANSPORT_CHANNEL, "TestServer: no free socket\n");
      return;
    }

    // Bind to *this node* and the requested serverPort
    addr.addr = TOS_NODE_ID;
    addr.port = serverPort;

    if (call Transport.bind(serverListenFd, &addr) != SUCCESS) {
      dbg(TRANSPORT_CHANNEL,
          "TestServer: bind failed for fd=%u on %u:%u\n",
          serverListenFd, addr.addr, addr.port);
      call Transport.release(serverListenFd);
      serverListenFd = 255;
      return;
    }

    if (call Transport.listen(serverListenFd) != SUCCESS) {
      dbg(TRANSPORT_CHANNEL,
          "TestServer: listen failed for fd=%u\n", serverListenFd);
      call Transport.release(serverListenFd);
      serverListenFd = 255;
      return;
    }

    // Reset accepted-client list and start polling with ServerTimer
    serverClientCount = 0;
    call ServerTimer.startPeriodic(100);

    dbg(TRANSPORT_CHANNEL,
        "Test server ready: fd=%u src=%u:%u\n",
        serverListenFd, addr.addr, addr.port);
  }

   event void CommandHandler.setTestClient(uint8_t serverNode, uint8_t clientSrcPort, uint8_t serverPort, uint8_t transferCount) {
    socket_addr_t src;
    socket_addr_t dst;

    dbg(TRANSPORT_CHANNEL, "TEST CLIENT EVENT\n");

    // Create a client socket
    clientFd = call Transport.socket();
    if (clientFd == 255) {
      dbg(TRANSPORT_CHANNEL, "TestClient: no free socket\n");
      return;
    }

    // Bind client to local address and requested src port
    src.addr = TOS_NODE_ID;
    src.port = clientSrcPort;

    if (call Transport.bind(clientFd, &src) != SUCCESS) {
      dbg(TRANSPORT_CHANNEL,
          "TestClient: bind failed for fd=%u on %u:%u\n",
          clientFd, src.addr, src.port);
      call Transport.release(clientFd);
      clientFd = 255;
      return;
    }

    // Destination: arbitrary server node + port passed by command
    dst.addr = serverNode;
    dst.port = serverPort;

    if (call Transport.connect(clientFd, &dst) != SUCCESS) {
      dbg(TRANSPORT_CHANNEL,
          "TestClient: connect failed for fd=%u -> %u:%u\n",
          clientFd, dst.addr, dst.port);
      call Transport.release(clientFd);
      clientFd = 255;
      return;
    }

    // Initialize streaming parameters for ClientTimer.fired()
    clientNextValue = 0;
    clientValuesLeft = transferCount;
    clientTransferMax = (transferCount > 0) ? (transferCount - 1) : 0;
    clientActive = TRUE;

    // Start periodic sends; your ClientTimer.fired() will handle writes
    call ClientTimer.startPeriodic(100);

    dbg(TRANSPORT_CHANNEL,
        "Client ready: fd=%u src=%u:%u -> dest=%u:%u transfer=%u values\n",
        clientFd, src.addr, src.port, dst.addr, dst.port, transferCount);
  }

  event void CommandHandler.chatStartServer() {
    uint8_t port = 41;
    dbg(TRANSPORT_CHANNEL,
        "CHAT CMD: start server on port %u\n", port);
    call ChatServer.start(port);
  }

  event void CommandHandler.chatStopServer() {
    dbg(TRANSPORT_CHANNEL, "CHAT CMD: stop server\n");
    call ChatServer.stop();
  }

  event void CommandHandler.chatHello(uint8_t *payload) {
    dbg(TRANSPORT_CHANNEL, "CHAT CMD: hello '%s'\n", (char*)payload);
    call ChatServer.chatHello(payload);
  }

  event void CommandHandler.chatMsg(uint8_t *payload) {
    dbg(TRANSPORT_CHANNEL, "CHAT CMD: msg '%s'\n", (char*)payload);
    call ChatServer.chatMsg(payload);
  }

  event void CommandHandler.chatWhisper(uint8_t *payload) {
    dbg(TRANSPORT_CHANNEL, "CHAT CMD: whisper '%s'\n", (char*)payload);
    call ChatServer.chatWhisper(payload);
  }

  event void CommandHandler.chatListUsr() {
    dbg(TRANSPORT_CHANNEL, "CHAT CMD: listusr\n");
    call ChatServer.chatListUsr();
  }

  event void CommandHandler.setAppServer(){
    dbg(TRANSPORT_CHANNEL, "APP SERVER EVENT\n");
    call ChatServer.start(41);
  }

  event void CommandHandler.setAppClient() {
    socket_addr_t src;
    socket_addr_t dst;
    uint8_t helloBuf[32];
    uint8_t len = 0;

    dbg(TRANSPORT_CHANNEL, "APP CLIENT EVENT\n");

    // If there was an old app client socket, close it.
    if (appClientFd != 255) {
      call Transport.close(appClientFd);
      appClientFd = 255;
    }

    // Create a new socket
    appClientFd = call Transport.socket();
    if (appClientFd == 255) {
      dbg(TRANSPORT_CHANNEL, "AppClient: no free socket\n");
      return;
    }

    // Bind to this node on a fixed "chat client" port (pick any not already used)
    src.addr = TOS_NODE_ID;
    src.port = 41;   // chat client port; just avoid 40/80 used by tests

    if (call Transport.bind(appClientFd, &src) != SUCCESS) {
      dbg(TRANSPORT_CHANNEL,
          "AppClient: bind failed for fd=%u on %u:%u\n",
          appClientFd, src.addr, src.port);
      call Transport.release(appClientFd);
      appClientFd = 255;
      return;
    }

    // Destination = chat server node and port.
    // Make sure this matches where you start the ChatServer
    // (CommandHandler.setAppServer uses ChatServer.start(80), so use port 80 here).
    dst.addr = 1;    // chat server node ID
    dst.port = 80;   // chat server port

    if (call Transport.connect(appClientFd, &dst) != SUCCESS) {
      dbg(TRANSPORT_CHANNEL,
          "AppClient: connect failed for fd=%u -> %u:%u\n",
          appClientFd, dst.addr, dst.port);
      call Transport.release(appClientFd);
      appClientFd = 255;
      return;
    }

    appServerAddr = dst;

    // Build a simple "hello <username>\r\n" message.
    // Username = "node<id>" (e.g., node4, node13)
    {
      uint8_t id = TOS_NODE_ID;
      char name[8];   // "node" + up to 3 digits + '\0'
      uint8_t npos = 0;
      uint8_t i;

      name[npos++] = 'n';
      name[npos++] = 'o';
      name[npos++] = 'd';
      name[npos++] = 'e';

      // Add decimal representation of TOS_NODE_ID
      if (id >= 100) {
        name[npos++] = '0' + (id / 100) % 10;
      }
      if (id >= 10) {
        name[npos++] = '0' + (id / 10) % 10;
      }
      name[npos++] = '0' + (id % 10);
      name[npos]   = '\0';

      // "hello "
      helloBuf[len++] = 'h';
      helloBuf[len++] = 'e';
      helloBuf[len++] = 'l';
      helloBuf[len++] = 'l';
      helloBuf[len++] = 'o';
      helloBuf[len++] = ' ';

      // copy username
      i = 0;
      while (name[i] != '\0' && len < sizeof(helloBuf) - 3) {
        helloBuf[len++] = (uint8_t)name[i++];
      }

      // "\r\n" terminator
      if (len < sizeof(helloBuf) - 2) {
        helloBuf[len++] = '\r';
        helloBuf[len++] = '\n';
      }
    }

    (void)call Transport.write(appClientFd, helloBuf, len);

    dbg(TRANSPORT_CHANNEL,
        "AppClient: connected fd=%u src=%u:%u -> dest=%u:%u, sent HELLO (len=%u)\n",
        appClientFd, src.addr, src.port, dst.addr, dst.port, len);
  }


   void makePack(pack *Package, uint16_t src, uint16_t dest, uint16_t TTL, uint16_t protocol, uint16_t seq, uint8_t* payload, uint8_t length){
      Package->src = src;
      Package->dest = dest;
      Package->TTL = TTL;
      Package->seq = seq;
      Package->protocol = protocol;
      memcpy(Package->payload, payload, length);
   }
}
