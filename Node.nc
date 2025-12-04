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
   uses interface Timer<TMilli> as ServerTimer;
   uses interface Timer<TMilli> as ClientTimer;
}

implementation{
   pack sendPackage;
   uint16_t floodSeq = 1;
   uint16_t pingSeq  = 0;
   socket_t serverListenFd = 255; // 255 = INVALID_SOCKET
   socket_t serverClients[MAX_NUM_OF_SOCKETS];
   uint8_t serverClientCount = 0;
   socket_t  clientFd = 255;
   socket_addr_t clientServerAddr;
   bool clientActive = FALSE;
   uint8_t cmdServerPort = 80;        // default, will be overwritten by payload
   uint16_t cmdClientDest = 4;        // server node ID
   uint8_t  cmdClientSrcPort = 40;
   uint8_t  cmdClientDestPort = 80;
   uint16_t cmdClientTransfer = 50;

   // we’ll send a sequence of uint16_t values 0..clientTransferMax
   uint16_t clientTransferMax = 0;
   uint16_t clientNextValue = 0;
   uint16_t clientValuesLeft = 0;

   socket_t testServerFd = 255;
   socket_t testClientFd = 255;

   void makePack(pack *Package, uint16_t src, uint16_t dest, uint16_t TTL,
                 uint16_t protocol, uint16_t seq, uint8_t *payload, uint8_t length);

   static void forward_by_ls(pack *p) {
      int16_t nh;
      if (p->TTL == 0) return;
      p->TTL--;

      nh = call LinkState.nextHop(p->dest);
      if (nh > 0) {
         call Sender.send(*p, (uint16_t)nh);
      } else {
         dbg(GENERAL_CHANNEL, "FORWARD: no route (nh=%d), trying direct to %u\n", nh, p->dest);
         call Sender.send(*p, p->dest);
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
         call Sender.send(pkt, (uint16_t)nh);
      } else {
         dbg(ROUTING_CHANNEL, "PING: no route to %u (nh=%d), trying direct\n", pkt.dest, nh);
         call Sender.send(pkt, pkt.dest);
      }
   }

   event void ServerTimer.fired() {
     socket_t newFd;
     uint8_t i;
     uint16_t n;
     uint8_t buf[64];

     if (serverListenFd == 255) {
       // server not running
       return;
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
       // you can also gracefully close here:
       // call Transport.close(clientFd);
       clientActive = FALSE;
       return;
     }

     // if all data in the buffer has been written or buffer is empty,
     // create new data for the buffer
     // data is 16-bit unsigned integers from 0 .. clientTransferMax

     // each uint16_t takes 2 bytes
     maxVals = sizeof(buf) / 2;
     valsToSend = clientValuesLeft;
     if (valsToSend > maxVals) valsToSend = maxVals;

     // Fill buf with valsToSend 16-bit values starting at clientNextValue
     for (i = 0; i < valsToSend; i++) {
       uint16_t v = clientNextValue + i;
       buf[2*i]   = (uint8_t)(v >> 8);   // high byte
       buf[2*i+1] = (uint8_t)(v & 0xFF); // low byte
     }

     bytesToSend = (uint16_t)(valsToSend * 2);

     bytesWritten = call Transport.write(clientFd, buf, bytesToSend);
     if (bytesWritten == 0) {
       // send buffer/window full or connection not yet ESTABLISHED;
       // we’ll try again on the next timer.
       dbg(TRANSPORT_CHANNEL, "Client: write() returned 0, retry later\n");
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
      call AMControl.start();
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
               call Transport.receive(myMsg);
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

     event void CommandHandler.setTestServer() {
    socket_addr_t addr;

    dbg(TRANSPORT_CHANNEL, "TEST SERVER EVENT\n");

    // Create a socket
    testServerFd = call Transport.socket();
    if (testServerFd == 255) {
      dbg(TRANSPORT_CHANNEL, "TestServer: no free socket\n");
      return;
    }

    // Bind it to this node and port 80 (server port for tests)
    addr.addr = TOS_NODE_ID;
    addr.port = 80;

    if (call Transport.bind(testServerFd, &addr) != SUCCESS) {
      dbg(TRANSPORT_CHANNEL,
          "TestServer: bind failed for fd=%u on %u:%u\n",
          testServerFd, addr.addr, addr.port);
      call Transport.release(testServerFd);
      testServerFd = 255;
      return;
    }

    // Listen on this socket
    if (call Transport.listen(testServerFd) != SUCCESS) {
      dbg(TRANSPORT_CHANNEL,
          "TestServer: listen failed for fd=%u\n", testServerFd);
      call Transport.release(testServerFd);
      testServerFd = 255;
      return;
    }

    dbg(TRANSPORT_CHANNEL,
        "Test server ready: fd=%u src=%u:%u\n",
        testServerFd, addr.addr, addr.port);
  }

    event void CommandHandler.setTestClient() {
      socket_addr_t src;
      socket_addr_t dst;
      uint8_t buf[51];      // small test payload
      uint16_t written;
      uint8_t i;

      dbg(TRANSPORT_CHANNEL, "TEST CLIENT EVENT\n");

      // Create a client socket
      testClientFd = call Transport.socket();
      if (testClientFd == 255) {
        dbg(TRANSPORT_CHANNEL, "TestClient: no free socket\n");
        return;
      }

      // Bind client to a local ephemeral port, e.g., 40
      src.addr = TOS_NODE_ID;
      src.port = 40;

      if (call Transport.bind(testClientFd, &src) != SUCCESS) {
        dbg(TRANSPORT_CHANNEL,
            "TestClient: bind failed for fd=%u on %u:%u\n",
            testClientFd, src.addr, src.port);
        call Transport.release(testClientFd);
        testClientFd = 255;
        return;
      }

      // Set destination to server node and port 80
      // For TestA/TestB, server node is passed from TestSim (e.g., node 1 or 13),
      // so the IP layer routes by dest.addr = that node ID.
      dst.addr = 1;        // <- change to the server node ID if needed
      dst.port = 80;       // server port

      if (call Transport.connect(testClientFd, &dst) != SUCCESS) {
        dbg(TRANSPORT_CHANNEL,
            "TestClient: connect failed for fd=%u -> %u:%u\n",
            testClientFd, dst.addr, dst.port);
        call Transport.release(testClientFd);
        testClientFd = 255;
        return;
      }

      dbg(TRANSPORT_CHANNEL,
          "Client ready: fd=%u src=%u:%u -> dest=%u:%u transfer=51 values\n",
          testClientFd, src.addr, src.port, dst.addr, dst.port);

      // Build a simple test payload 0..50
      for (i = 0; i < 51; i++) {
        buf[i] = i;
      }

      // Try a single write (mid-review: just initial data transfer)
      written = call Transport.write(testClientFd, buf, 51);
      dbg(TRANSPORT_CHANNEL,
          "Client: write() returned %u\n", written);

      // Mid-review: simple teardown after one write
      call Transport.close(testClientFd);
      testClientFd = 255;
    }


   event void CommandHandler.setAppServer(){}
   event void CommandHandler.setAppClient(){}

   void makePack(pack *Package, uint16_t src, uint16_t dest, uint16_t TTL, uint16_t protocol, uint16_t seq, uint8_t* payload, uint8_t length){
      Package->src = src;
      Package->dest = dest;
      Package->TTL = TTL;
      Package->seq = seq;
      Package->protocol = protocol;
      memcpy(Package->payload, payload, length);
   }
}
