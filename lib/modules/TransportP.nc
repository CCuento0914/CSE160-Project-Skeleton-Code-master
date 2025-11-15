#include "../../includes/socket.h"
#include "../../includes/packet.h"
#include "../../includes/protocol.h"
#include "../../includes/channels.h"

#define INVALID_SOCKET 255
#define TCP_HEADER_LEN 8
#define DATA_MAX_LEN (PACKET_MAX_PAYLOAD_SIZE - TCP_HEADER_LEN)

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
  //uses interface Timer<TMilli> as retransTimer;
}
implementation {
  socket_store_t socketTable[MAX_NUM_OF_SOCKETS];
  uint8_t nextSeq = 1;

  socket_t findSocketByPort(uint8_t port) {
    uint8_t i;
    for (i = 0; i < MAX_NUM_OF_SOCKETS; i++) {
      if (socketTable[i].flag && socketTable[i].src == port) {
        return i;
      }
    }
    return INVALID_SOCKET;
  }

  void sendSegment(socket_t fd, uint8_t flags, uint8_t *data, uint16_t len) {
    pack pkt;
    tcp_hdr_t *hdr;
    uint16_t totalLen;
    uint8_t *payloadPtr;

    if (fd >= MAX_NUM_OF_SOCKETS) return;

    memset(&pkt, 0, sizeof(pack));
    pkt.src = TOS_NODE_ID;
    pkt.dest = socketTable[fd].dest.addr;
    pkt.protocol = PROTOCOL_TCP;
    pkt.TTL = 30;
    pkt.seq = nextSeq++;

    hdr = (tcp_hdr_t*) (void*) pkt.payload;
    hdr->srcPort = socketTable[fd].src;
    hdr->destPort = socketTable[fd].dest.port;
    hdr->seq = socketTable[fd].lastSent;
    hdr->ack = socketTable[fd].lastAck;
    hdr->flags = flags;
    hdr->window = socketTable[fd].effectiveWindow;
    hdr->length = len;

    payloadPtr = (uint8_t*) (void*) (pkt.payload + TCP_HEADER_LEN);
    if (len > 0 && data != NULL) {
      memcpy(payloadPtr, data, len);
    }

    totalLen = TCP_HEADER_LEN + len;
    call Sender.send(pkt, pkt.dest);
    dbg(TRANSPORT_CHANNEL, "TCP SEND: fd=%u flags=0x%x len=%u -> %u:%u\n",
        fd, flags, totalLen, pkt.dest, hdr->destPort);
  }

  command socket_t Transport.socket() {
    uint8_t i;
    for (i = 0; i < MAX_NUM_OF_SOCKETS; i++) {
      if (socketTable[i].flag == 0) {
        socketTable[i].flag = 1;
        socketTable[i].state = CLOSED;
        socketTable[i].effectiveWindow = SOCKET_BUFFER_SIZE;
        socketTable[i].lastSent = 0;
        socketTable[i].lastAck = 0;
        socketTable[i].lastRcvd = 0;
        socketTable[i].nextExpected = 0;
        dbg(TRANSPORT_CHANNEL, "SOCKET[%d]: Created\n", i);
        return i;
      }
    }
    dbg(TRANSPORT_CHANNEL, "SOCKET: No free slots\n");
    return INVALID_SOCKET;
  }

  command error_t Transport.bind(socket_t fd, socket_addr_t* addr) {
    if (fd >= MAX_NUM_OF_SOCKETS) return FAIL;
    socketTable[fd].src = addr->port;
    dbg(TRANSPORT_CHANNEL, "SOCKET[%d]: Bound to port %d\n", fd, addr->port);
    return SUCCESS;
  }

  command error_t Transport.listen(socket_t fd) {
    if (fd >= MAX_NUM_OF_SOCKETS) return FAIL;
    socketTable[fd].state = LISTEN;
    dbg(TRANSPORT_CHANNEL, "SOCKET[%d]: Listening on port %d\n",
        fd, socketTable[fd].src);
    return SUCCESS;
  }

  command error_t Transport.connect(socket_t fd, socket_addr_t* addr) {
    if (fd >= MAX_NUM_OF_SOCKETS) return FAIL;
    socketTable[fd].dest = *addr;
    socketTable[fd].state = SYN_SENT;
    dbg(TRANSPORT_CHANNEL, "SOCKET[%d]: Sending SYN -> %u:%u\n",
        fd, addr->addr, addr->port);
    sendSegment(fd, TCP_SYN, NULL, 0);
    return SUCCESS;
  }

  command socket_t Transport.accept(socket_t fd) {
    if (fd >= MAX_NUM_OF_SOCKETS) return INVALID_SOCKET;
    if (socketTable[fd].state != SYN_RCVD) return INVALID_SOCKET;
    socketTable[fd].state = ESTABLISHED;
    dbg(TRANSPORT_CHANNEL, "SOCKET[%u]: Accept complete\n", fd);
    return fd;
  }

  command error_t Transport.receive(pack* p) {
    tcp_hdr_t *hdr;
    socket_t fd;

    hdr = (tcp_hdr_t*) (void*) p->payload;
    fd = findSocketByPort(hdr->destPort);
    if (fd == INVALID_SOCKET) {
      dbg(TRANSPORT_CHANNEL, "RECV: No matching socket for port %u\n", hdr->destPort);
      return FAIL;
    }

    if (hdr->flags & TCP_SYN) {
      if (socketTable[fd].state == LISTEN) {
        socketTable[fd].dest.addr = p->src;
        socketTable[fd].dest.port = hdr->srcPort;
        socketTable[fd].state = SYN_RCVD;
        dbg(TRANSPORT_CHANNEL, "SOCKET[%u]: Got SYN, sending SYN-ACK\n", fd);
        sendSegment(fd, TCP_SYN | TCP_ACK, NULL, 0);
      }
    } else if (hdr->flags & TCP_ACK) {
      if (socketTable[fd].state == SYN_SENT) {
        socketTable[fd].state = ESTABLISHED;
        dbg(TRANSPORT_CHANNEL, "SOCKET[%u]: Connection established (client)\n", fd);
      } else if (socketTable[fd].state == SYN_RCVD) {
        socketTable[fd].state = ESTABLISHED;
        dbg(TRANSPORT_CHANNEL, "SOCKET[%u]: Connection established (server)\n", fd);
      }
    } else if (hdr->flags & TCP_FIN) {
      dbg(TRANSPORT_CHANNEL, "SOCKET[%u]: Got FIN, closing\n", fd);
      socketTable[fd].state = CLOSED;
      socketTable[fd].flag = 0;
    } else if (hdr->flags & TCP_DATA) {
      uint16_t len = hdr->length;
      if (len > 0 && len <= DATA_MAX_LEN) {
        memcpy(socketTable[fd].rcvdBuff, p->payload + TCP_HEADER_LEN, len);
        socketTable[fd].lastRcvd = hdr->seq;
        socketTable[fd].nextExpected = hdr->seq + len;
        dbg(TRANSPORT_CHANNEL, "SOCKET[%u]: DATA received (%u bytes)\n", fd, len);
        sendSegment(fd, TCP_ACK, NULL, 0);
      }
    }
    return SUCCESS;
  }

  command uint16_t Transport.write(socket_t fd, uint8_t *buff, uint16_t len) {
    if (fd >= MAX_NUM_OF_SOCKETS) return 0;
    if (socketTable[fd].state != ESTABLISHED) return 0;
    if (len > DATA_MAX_LEN) len = DATA_MAX_LEN;
    sendSegment(fd, TCP_DATA, buff, len);
    return len;
  }

  command uint16_t Transport.read(socket_t fd, uint8_t *buff, uint16_t bufflen) {
    uint16_t n;
    if (fd >= MAX_NUM_OF_SOCKETS) return 0;
    if (socketTable[fd].state != ESTABLISHED) return 0;
    n = socketTable[fd].lastRcvd;
    if (bufflen < n) n = bufflen;
    memcpy(buff, socketTable[fd].rcvdBuff, n);
    return n;
  }

  command error_t Transport.close(socket_t fd) {
    if (fd >= MAX_NUM_OF_SOCKETS) return FAIL;
    sendSegment(fd, TCP_FIN, NULL, 0);
    socketTable[fd].state = CLOSED;
    socketTable[fd].flag = 0;
    dbg(TRANSPORT_CHANNEL, "SOCKET[%u]: Closed\n", fd);
    return SUCCESS;
  }

  command error_t Transport.release(socket_t fd) {
    if (fd >= MAX_NUM_OF_SOCKETS) return FAIL;
    socketTable[fd].state = CLOSED;
    socketTable[fd].flag = 0;
    dbg(TRANSPORT_CHANNEL, "SOCKET[%u]: Released (hard close)\n", fd);
    return SUCCESS;
  }
}
