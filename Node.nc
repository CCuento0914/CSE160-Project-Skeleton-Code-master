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
}

implementation{
   pack sendPackage;
   uint16_t floodSeq = 1;
   uint16_t pingSeq  = 0;

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

   event void CommandHandler.printNeighbors(){
      dbg(GENERAL_CHANNEL, "PRINT NEIGHBORS EVENT \n");
      call NeighborDiscover.printNeighbors();
   }

   event void CommandHandler.printLinkState() {
      dbg(COMMAND_CHANNEL, "PRINT LINKSTATE EVENT\n");
      call LinkState.routeDump();
   }

   event void CommandHandler.printRouteTable() {
      dbg(COMMAND_CHANNEL, "PRINT ROUTETABLE EVENT\n");
      call LinkState.routeDump();
   }
   
   event void CommandHandler.printDistanceVector(){}

   event void CommandHandler.setTestServer(){
      socket_t s;
      socket_addr_t me;
      error_t er;
      dbg(GENERAL_CHANNEL, "TEST SERVER EVENT\n");

     s = call Transport.socket();
     if (s == 255) { dbg(TRANSPORT_CHANNEL, "No socket available\n"); return; }

     me.addr = TOS_NODE_ID;   // local node id
     me.port = 80;            // example server port
     if (call Transport.bind(s, &me) != SUCCESS) {
       dbg(TRANSPORT_CHANNEL, "bind failed\n"); return;
     }
     if (call Transport.listen(s) != SUCCESS) {
       dbg(TRANSPORT_CHANNEL, "listen failed\n"); return;
     }
     dbg(TRANSPORT_CHANNEL, "Server ready on %u:%u (fd=%u)\n", me.addr, me.port, s);
   }

   event void CommandHandler.setTestClient(){
      socket_t c;
      socket_addr_t me;
      socket_addr_t srv;
      error_t er;
      uint8_t helloBuf[32];
      uint16_t n;
      dbg(GENERAL_CHANNEL, "TEST CLIENT EVENT\n");

      c = call Transport.socket();
      if (c == 255) { dbg(TRANSPORT_CHANNEL, "No client socket\n"); return; }

      srv.addr = 1;  // server node id from your test
      srv.port = 80; // server port

      if (call Transport.connect(c, &srv) != SUCCESS) {
         dbg(TRANSPORT_CHANNEL, "connect failed\n"); return;
      }
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
