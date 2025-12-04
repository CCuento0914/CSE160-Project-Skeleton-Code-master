#include "../../includes/socket.h"
#include "../../includes/packet.h"
#include "../../includes/protocol.h"
#include "../../includes/channels.h"
#include <Timer.h>

#define INVALID_SOCKET 255
#define TCP_HEADER_LEN 8
#define DATA_MAX_LEN (PACKET_MAX_PAYLOAD_SIZE - TCP_HEADER_LEN)


#define RETRANS_TIMEOUT_MS 500


#define FIXED_SEND_WINDOW 64 

enum tcp_flags {
  TCP_SYN = 0x01,
  TCP_ACK = 0x02,
  TCP_FIN = 0x04,
  TCP_DATA = 0x08
};

typedef nx_struct tcp_hdr_t {
  nx_uint8_t srcPort;
  nx_uint8_t destPort;
  nx_uint8_t seq; 
  nx_uint8_t ack;
  nx_uint8_t flags;
  nx_uint8_t window; 
  nx_uint16_t length;
} tcp_hdr_t;

module TransportP {
  provides interface Transport;
  uses interface SimpleSend as Sender;
  uses interface LinkState;
  uses interface IP;
  uses interface Timer<TMilli> as retransTimer;
}

implementation {
  socket_store_t socketTable[MAX_NUM_OF_SOCKETS];

  uint8_t sendBuff[MAX_NUM_OF_SOCKETS][SOCKET_BUFFER_SIZE];
  uint8_t lastWritten[MAX_NUM_OF_SOCKETS]; 
  uint8_t peerWindow[MAX_NUM_OF_SOCKETS]; 
  bool retransActive[MAX_NUM_OF_SOCKETS];
  uint8_t parentFd[MAX_NUM_OF_SOCKETS]; 
  uint8_t nextPktSeq = 1;

  // find a listening socket by local port
  socket_t findListeningSocket(uint8_t localPort) {
    uint8_t i;
    for (i = 0; i < MAX_NUM_OF_SOCKETS; i++) {
      if (socketTable[i].flag &&
          socketTable[i].state == LISTEN &&
          socketTable[i].src == localPort) {
        return i;
      }
    }
    return INVALID_SOCKET;
  }

  // find an existing non-listening connection by full 4-tuple
  socket_t findActiveSocket(uint16_t srcAddr, uint8_t srcPort, uint16_t destAddr, uint8_t destPort) {
    uint8_t i;
    for (i = 0; i < MAX_NUM_OF_SOCKETS; i++) {
      if (socketTable[i].flag &&
          socketTable[i].state != LISTEN &&
          socketTable[i].src == destPort &&    
          socketTable[i].dest.addr == srcAddr &&  
          socketTable[i].dest.port == srcPort &&     
          destAddr == TOS_NODE_ID) {
        return i;
      }
    }
    return INVALID_SOCKET;
  }

  // internal allocator for a new socket entry
  socket_t allocSocketEntry() {
    uint8_t i;
    for (i = 0; i < MAX_NUM_OF_SOCKETS; i++) {
      if (!socketTable[i].flag) {
        socketTable[i].flag = 1;
        socketTable[i].state = CLOSED;
        socketTable[i].effectiveWindow = SOCKET_BUFFER_SIZE;

        socketTable[i].lastSent = 0;
        socketTable[i].lastAck = 0;
        socketTable[i].lastRcvd = 0;
        socketTable[i].nextExpected = 0;

        lastWritten[i] = 0;
        peerWindow[i] = SOCKET_BUFFER_SIZE;
        retransActive[i] = FALSE;
        parentFd[i] = INVALID_SOCKET;

        return i;
      }
    }
    return INVALID_SOCKET;
  }

  // ---------- send a single TCP segment ----------
  void sendSegment(socket_t fd, uint8_t flags, uint8_t seqByte, uint8_t ackByte, uint8_t *data, uint16_t len) {
    pack pkt;
    tcp_hdr_t *hdr;
    uint8_t *payloadPtr;

    if (fd >= MAX_NUM_OF_SOCKETS) return;
    if (!socketTable[fd].flag) return;
    if ((flags & (TCP_SYN | TCP_ACK | TCP_FIN)) && (len > 0)) {
      dbg(TRANSPORT_CHANNEL,
          "ERROR: Control packet (flags=0x%x) cannot carry data, dropping\n",
          flags);
      return;
    }

    memset(&pkt, 0, sizeof(pack));
    pkt.src = TOS_NODE_ID;
    pkt.dest = socketTable[fd].dest.addr;
    pkt.protocol = PROTOCOL_TCP;
    pkt.TTL = 30;
    pkt.seq = nextPktSeq++; 

    hdr = (tcp_hdr_t*)(void*)pkt.payload;
    hdr->srcPort = socketTable[fd].src;
    hdr->destPort = socketTable[fd].dest.port;
    hdr->seq = seqByte;
    hdr->ack = ackByte;
    hdr->flags = flags;

    // advertised window = how much recv buffer we have left
    {
      uint8_t avail = SOCKET_BUFFER_SIZE - socketTable[fd].lastRcvd;
      socketTable[fd].effectiveWindow = avail;
      hdr->window = avail;
    }

    hdr->length = len;

    payloadPtr = (uint8_t*)(void*)(pkt.payload + TCP_HEADER_LEN);
    if (len > 0 && data != NULL) {
      memcpy(payloadPtr, data, len);
    }

    call Sender.send(pkt, pkt.dest);

    dbg(TRANSPORT_CHANNEL,
        "TCP SEND: fd=%u flags=0x%x seq=%u ack=%u len=%u win=%u -> %u:%u\n",
        fd, flags, hdr->seq, hdr->ack, len, hdr->window,
        pkt.dest, hdr->destPort);
  }

  // ---------- sliding window sender: send as many segments as allowed ----------
  void sendAvailableSegments(socket_t fd) {
    uint8_t unacked, unsent, windowLimit, canSend;
    uint8_t segLen, seqStart;

    if (fd >= MAX_NUM_OF_SOCKETS) return;
    if (!socketTable[fd].flag) return;
    if (socketTable[fd].state != ESTABLISHED) return;

    // bytes already sent but not yet ACKed
    unacked = socketTable[fd].lastSent - socketTable[fd].lastAck;

    // total window allowed: min(fixed window, peer advertised window)
    windowLimit = FIXED_SEND_WINDOW;
    if (peerWindow[fd] < windowLimit) windowLimit = peerWindow[fd];

    if (unacked >= windowLimit) {
      // window full, cannot send more
      return;
    }
    canSend = windowLimit - unacked;

    unsent = lastWritten[fd] - socketTable[fd].lastSent;
    while (unsent > 0 && canSend > 0) {
      segLen = unsent;
      if (segLen > DATA_MAX_LEN) segLen = DATA_MAX_LEN;
      if (segLen > canSend)      segLen = canSend;

      seqStart = socketTable[fd].lastSent;

      dbg(TRANSPORT_CHANNEL,
          "SOCKET[%u]: sendAvailable unsent=%u unacked=%u segLen=%u seq=%u\n",
          fd, unsent, unacked, segLen, seqStart);

      sendSegment(fd, TCP_DATA, seqStart, socketTable[fd].nextExpected, &sendBuff[fd][seqStart], segLen);

      socketTable[fd].lastSent += segLen;
      unacked += segLen;
      canSend -= segLen;
      unsent -= segLen;
      retransActive[fd] = TRUE;

      // (re)start retransmission timer whenever we have unacked data
      call retransTimer.startOneShot(RETRANS_TIMEOUT_MS);
    }
  }

  // ---------- public API: socket/bind/listen/connect/accept ----------

  command socket_t Transport.socket() {
    socket_t fd = allocSocketEntry();
    if (fd == INVALID_SOCKET) {
      dbg(TRANSPORT_CHANNEL, "SOCKET: No free slots\n");
    } else {
      dbg(TRANSPORT_CHANNEL, "SOCKET[%u]: Created\n", fd);
    }
    return fd;
  }

  command error_t Transport.bind(socket_t fd, socket_addr_t* addr) {
    if (fd >= MAX_NUM_OF_SOCKETS) return FAIL;
    socketTable[fd].src = addr->port;   // local port only
    dbg(TRANSPORT_CHANNEL, "SOCKET[%u]: Bound to port %u\n", fd, addr->port);
    return SUCCESS;
  }

  command error_t Transport.listen(socket_t fd) {
    if (fd >= MAX_NUM_OF_SOCKETS) return FAIL;
    socketTable[fd].state = LISTEN;
    dbg(TRANSPORT_CHANNEL,
        "SOCKET[%u]: Listening on port %u\n",
        fd, socketTable[fd].src);
    return SUCCESS;
  }

  command error_t Transport.connect(socket_t fd, socket_addr_t* addr) {
    if (fd >= MAX_NUM_OF_SOCKETS) return FAIL;

    // set peer info
    socketTable[fd].dest = *addr;
    socketTable[fd].state = SYN_SENT;

    // init stream indices
    socketTable[fd].lastSent = 0;
    socketTable[fd].lastAck = 0;
    socketTable[fd].lastRcvd = 0;
    socketTable[fd].nextExpected = 0;
    lastWritten[fd] = 0;
    peerWindow[fd] = SOCKET_BUFFER_SIZE;
    retransActive[fd] = FALSE;
    parentFd[fd] = INVALID_SOCKET;

    dbg(TRANSPORT_CHANNEL, "SOCKET[%u]: Sending SYN -> %u:%u\n",
        fd, addr->addr, addr->port);

    // SYN has no payload; seq/ack both 0
    sendSegment(fd, TCP_SYN, 0, 0, NULL, 0);
    return SUCCESS;
  }

  command socket_t Transport.accept(socket_t listenFd) {
    uint8_t i;

    if (listenFd >= MAX_NUM_OF_SOCKETS) return INVALID_SOCKET;
    if (socketTable[listenFd].state != LISTEN) return INVALID_SOCKET;

    // look for any child socket in SYN_RCVD or ESTABLISHED for this listener
    for (i = 0; i < MAX_NUM_OF_SOCKETS; i++) {
      if (socketTable[i].flag &&
          parentFd[i] == listenFd &&
          (socketTable[i].state == SYN_RCVD ||
           socketTable[i].state == ESTABLISHED)) {

        if (socketTable[i].state == SYN_RCVD) {
          socketTable[i].state = ESTABLISHED;
        }

        dbg(TRANSPORT_CHANNEL,
            "SOCKET[%u]: Accept returning child fd=%u\n",
            listenFd, i);
        return i;
      }
    }
    return INVALID_SOCKET;
  }

  event void retransTimer.fired() {
    uint8_t i;

    for (i = 0; i < MAX_NUM_OF_SOCKETS; i++) {
      if (socketTable[i].flag &&
          socketTable[i].state == ESTABLISHED &&
          retransActive[i]) {

        uint8_t inFlight = socketTable[i].lastSent - socketTable[i].lastAck;
        if (inFlight == 0) {
          retransActive[i] = FALSE;
          continue;
        }

        dbg(TRANSPORT_CHANNEL,
            "SOCKET[%u]: timeout, retransmitting %u bytes from %u\n",
            i, inFlight, socketTable[i].lastAck);

        sendSegment(i, TCP_DATA, socketTable[i].lastAck, socketTable[i].nextExpected, &sendBuff[i][socketTable[i].lastAck], inFlight);

        call retransTimer.startOneShot(RETRANS_TIMEOUT_MS);
      }
    }
  }

  command error_t Transport.receive(pack* p) {
    tcp_hdr_t *hdr;
    socket_t fd;
    uint16_t srcAddr = p->src;
    uint16_t destAddr = p->dest; 

    hdr = (tcp_hdr_t*)(void*)p->payload;

    // First see if this belongs to an existing connection
    fd = findActiveSocket(srcAddr, hdr->srcPort, destAddr, hdr->destPort);

    // If no active connection and this is a SYN, try to match a listener
    if (fd == INVALID_SOCKET && (hdr->flags & TCP_SYN)) {
      socket_t listenFd = findListeningSocket(hdr->destPort);
      if (listenFd != INVALID_SOCKET) {
        // allocate a new child socket for this 4-tuple
        fd = allocSocketEntry();
        if (fd != INVALID_SOCKET) {
          socketTable[fd].src = hdr->destPort;  
          socketTable[fd].dest.addr = srcAddr; 
          socketTable[fd].dest.port = hdr->srcPort; 
          socketTable[fd].state = SYN_RCVD;

          socketTable[fd].lastSent = 0;
          socketTable[fd].lastAck = 0;
          socketTable[fd].lastRcvd = 0;
          socketTable[fd].nextExpected = 0;
          lastWritten[fd] = 0;
          peerWindow[fd] = SOCKET_BUFFER_SIZE;
          retransActive[fd] = FALSE;
          parentFd[fd] = listenFd;

          dbg(TRANSPORT_CHANNEL, "SOCKET[%u]: Got SYN from %u:%u, child fd=%u, sending SYN-ACK\n",
              listenFd, srcAddr, hdr->srcPort, fd);

          // SYN-ACK: no payload, seq=0, ack=1 (or hdr->seq+1)
          sendSegment(fd, TCP_SYN | TCP_ACK, 0, hdr->seq + 1, NULL, 0);
          return SUCCESS;
        }
      }
      dbg(TRANSPORT_CHANNEL,
          "RECV: SYN for port %u but no listener or no slots\n",
          hdr->destPort);
      return FAIL;
    }

    if (fd == INVALID_SOCKET) {
      dbg(TRANSPORT_CHANNEL,
          "RECV: No matching connection for (%u:%u -> %u:%u)\n",
          srcAddr, hdr->srcPort, destAddr, hdr->destPort);
      return FAIL;
    }

    peerWindow[fd] = hdr->window;

    // Update dest info (helpful if we hadn’t filled earlier)
    socketTable[fd].dest.addr = srcAddr;
    socketTable[fd].dest.port = hdr->srcPort;

    // ---------- handle FLAGS ----------

    if (hdr->flags & TCP_SYN) {
      // Should only see here if we were passive and already in SYN_RCVD
      // Nothing extra to do; SYN-ACK already sent above.
      dbg(TRANSPORT_CHANNEL,
          "SOCKET[%u]: Received extra SYN (ignored)\n", fd);
    }
    else if (hdr->flags & TCP_FIN) {
      dbg(TRANSPORT_CHANNEL, "SOCKET[%u]: Got FIN, sending ACK and closing\n", fd);
      // ACK the FIN (no data)
      sendSegment(fd, TCP_ACK, 0, hdr->seq + 1, NULL, 0);

      // Simplified close, free socket immediately
      socketTable[fd].state = CLOSED;
      socketTable[fd].flag  = 0;
      retransActive[fd] = FALSE;
    }
    else if (hdr->flags & TCP_ACK) {
      // ACK for handshake or data
      if (socketTable[fd].state == SYN_SENT) {
        socketTable[fd].state = ESTABLISHED;
        dbg(TRANSPORT_CHANNEL,
            "SOCKET[%u]: Connection ESTABLISHED (client)\n", fd);
      }
      else if (socketTable[fd].state == SYN_RCVD) {
        socketTable[fd].state = ESTABLISHED;
        dbg(TRANSPORT_CHANNEL,
            "SOCKET[%u]: Connection ESTABLISHED (server)\n", fd);
      }
      else if (socketTable[fd].state == ESTABLISHED) {
        // Data ACK: hdr->ack is next expected byte from sender’s side
        uint8_t oldAck = socketTable[fd].lastAck;
        uint8_t ackVal = hdr->ack;

        // advance lastAck only forward, up to lastSent
        if (ackVal > socketTable[fd].lastAck &&
            ackVal <= socketTable[fd].lastSent) {
          socketTable[fd].lastAck = ackVal;

          dbg(TRANSPORT_CHANNEL,
              "SOCKET[%u]: DATA ACK received ack=%u (from %u)\n",
              fd, ackVal, oldAck);
        }

        // if all data ACKed, we may stop retrans timer
        if (socketTable[fd].lastAck == socketTable[fd].lastSent) {
          retransActive[fd] = FALSE;
        }

        // if still unacked data, keep timer running
        if (retransActive[fd]) {
          call retransTimer.startOneShot(RETRANS_TIMEOUT_MS);
        }

        // if app wrote more and window allows, send more
        sendAvailableSegments(fd);
      }
    }
    else if (hdr->flags & TCP_DATA) {
      // DATA: use seq as byte offset
      uint16_t len = hdr->length;
      if (len > 0 && len <= DATA_MAX_LEN) {
        if (hdr->seq == socketTable[fd].nextExpected) {
          // in-order; copy into receive buffer
          uint8_t space = SOCKET_BUFFER_SIZE - socketTable[fd].lastRcvd;
          if (len > space) len = space;

          memcpy(&socketTable[fd].rcvdBuff[socketTable[fd].lastRcvd],
                 p->payload + TCP_HEADER_LEN,
                 len);

          socketTable[fd].lastRcvd     += len;
          socketTable[fd].nextExpected += len;

          dbg(TRANSPORT_CHANNEL,
              "SOCKET[%u]: DATA in-order (%u bytes) seq=%u nextExpected=%u\n",
              fd, len, hdr->seq, socketTable[fd].nextExpected);
        } else {
          // out-of-order; ignore data but still ACK last good byte
          dbg(TRANSPORT_CHANNEL,
              "SOCKET[%u]: DATA out-of-order seq=%u expected=%u (ignored)\n",
              fd, hdr->seq, socketTable[fd].nextExpected);
        }

        // send ACK for every data packet
        sendSegment(fd, TCP_ACK, 0, socketTable[fd].nextExpected, NULL, 0);
      }
    }

    return SUCCESS;
  }

  // Application write(): sliding window & buffering

  command uint16_t Transport.write(socket_t fd, uint8_t *buff, uint16_t len) {
    uint8_t space;

    if (fd >= MAX_NUM_OF_SOCKETS) return 0;
    if (!socketTable[fd].flag) return 0;
    if (socketTable[fd].state != ESTABLISHED) return 0;

    // available space in send buffer (byte ring, no wrap handling for simplicity)
    if (lastWritten[fd] >= socketTable[fd].lastAck)
      space = SOCKET_BUFFER_SIZE - (lastWritten[fd] - socketTable[fd].lastAck);
    else
      space = socketTable[fd].lastAck - lastWritten[fd];

    if (len > space) len = space;
    if (len == 0) return 0;

    memcpy(&sendBuff[fd][lastWritten[fd]], buff, len);
    lastWritten[fd] += len;

    dbg(TRANSPORT_CHANNEL,
        "SOCKET[%u]: write len=%u lastAck=%u lastSent=%u lastWritten=%u\n",
        fd, len, socketTable[fd].lastAck,
        socketTable[fd].lastSent, lastWritten[fd]);
    sendAvailableSegments(fd);

    return len;
  }

  // ---------- Application read(): pull bytes from rcvdBuff ----------

  command uint16_t Transport.read(socket_t fd, uint8_t *buff, uint16_t bufflen) {
    uint16_t n;

    if (fd >= MAX_NUM_OF_SOCKETS) return 0;
    if (!socketTable[fd].flag) return 0;
    if (socketTable[fd].state != ESTABLISHED) return 0;

    n = socketTable[fd].lastRcvd;
    if (n == 0) return 0;

    if (bufflen < n) n = bufflen;
    memcpy(buff, socketTable[fd].rcvdBuff, n);

    // consume everything we give to app
    socketTable[fd].lastRcvd = 0;

    dbg(TRANSPORT_CHANNEL,
        "SOCKET[%u]: read returning %u bytes\n", fd, n);

    return n;
  }

  // ---------- close / release (FIN) ----------

  command error_t Transport.close(socket_t fd) {
    if (fd >= MAX_NUM_OF_SOCKETS) return FAIL;
    if (!socketTable[fd].flag) return FAIL;

    dbg(TRANSPORT_CHANNEL, "SOCKET[%u]: Sending FIN\n", fd);

    // FIN: control packet, no data
    sendSegment(fd, TCP_FIN, 0, 0, NULL, 0);

    // simplified: free immediately after sending
    socketTable[fd].state = CLOSED;
    socketTable[fd].flag  = 0;
    retransActive[fd] = FALSE;
    return SUCCESS;
  }

  command error_t Transport.release(socket_t fd) {
    if (fd >= MAX_NUM_OF_SOCKETS) return FAIL;
    socketTable[fd].state = CLOSED;
    socketTable[fd].flag  = 0;
    retransActive[fd]     = FALSE;
    dbg(TRANSPORT_CHANNEL,
        "SOCKET[%u]: Released (hard close)\n", fd);
    return SUCCESS;
  }
}
