#include <string.h>
#include <Timer.h>
#include "../../includes/socket.h"
#include "../../includes/channels.h"

module ChatServerP {
  provides interface ChatServer;
  uses interface Transport;
  uses interface Timer<TMilli> as ChatTimer;
}
implementation {

  enum {
    CHAT_MAX_CLIENTS = 8,
    CHAT_NAME_MAX = 16,
    CHAT_LINE_MAX = 80, 
    INVALID_FD = 255
  };

  typedef struct {
    uint8_t inUse;
    socket_t fd;
    char name[CHAT_NAME_MAX]; 
    char inbuf[CHAT_LINE_MAX]; 
    uint8_t inlen;
  } chat_client_t;

  static socket_t listenFd = INVALID_FD;
  static chat_client_t clients[CHAT_MAX_CLIENTS];

  // -------- small string helpers (no snprintf) --------

  static void str_clear(char *s, uint8_t cap) {
    if (cap > 0) s[0] = '\0';
  }

  static void str_cat(char *dst, uint8_t cap, const char *src) {
    uint8_t d = 0;
    while (d < cap && dst[d] != '\0') d++;
    while (d + 1 < cap && *src) {
      dst[d++] = *src++;
    }
    if (d < cap) dst[d] = '\0';
  }

  static void str_cat_n(char *dst, uint8_t cap, const char *src, uint8_t n) {
    uint8_t d = 0;
    while (d < cap && dst[d] != '\0') d++;
    while (d + 1 < cap && n > 0 && *src) {
      dst[d++] = *src++;
      n--;
    }
    if (d < cap) dst[d] = '\0';
  }

  // -------- client table helpers --------

  static void resetClients() {
    uint8_t i;
    for (i = 0; i < CHAT_MAX_CLIENTS; i++) {
      clients[i].inUse = 0;
      clients[i].fd = INVALID_FD;
      clients[i].name[0] = '\0';
      clients[i].inlen = 0;
      clients[i].inbuf[0] = '\0';
    }
  }

  static int8_t findFreeSlot() {
    uint8_t i;
    for (i = 0; i < CHAT_MAX_CLIENTS; i++) {
      if (!clients[i].inUse) return (int8_t)i;
    }
    return -1;
  }

  static int8_t findByName(const char *name) {
    uint8_t i;
    for (i = 0; i < CHAT_MAX_CLIENTS; i++) {
      if (clients[i].inUse && clients[i].name[0] != '\0') {
        if (strncmp(clients[i].name, name, CHAT_NAME_MAX) == 0) return (int8_t)i;
      }
    }
    return -1;
  }

  static void sendTo(socket_t fd, const char *s) {
    uint16_t len = (uint16_t)strlen(s);
    if (len == 0) return;
    (void)call Transport.write(fd, (uint8_t*)s, len);
  }

  static void broadcast(const char *s) {
    uint8_t i;
    for (i = 0; i < CHAT_MAX_CLIENTS; i++) {
      if (clients[i].inUse) sendTo(clients[i].fd, s);
    }
  }

  static void dropClient(uint8_t i) {
    if (!clients[i].inUse) return;
    dbg(CHAT_CHANNEL, "CHAT: drop fd=%u name=%s\n", clients[i].fd, clients[i].name);
    call Transport.close(clients[i].fd);
    clients[i].inUse = 0;
    clients[i].fd = INVALID_FD;
    clients[i].name[0] = '\0';
    clients[i].inlen = 0;
    clients[i].inbuf[0] = '\0';
  }

  // -------- parsing helpers --------

  // returns index of "\r\n" start, or -1
  static int16_t findCRLF(const char *buf, uint8_t n) {
    uint8_t i;
    if (n < 2) return -1;
    for (i = 0; i + 1 < n; i++) {
      if (buf[i] == '\r' && buf[i+1] == '\n') return (int16_t)i;
    }
    return -1;
  }

  // trims leading spaces
  static char* skipSpaces(char *p) {
    while (*p == ' ') p++;
    return p;
  }

  // Extract first token into out (null-terminated), returns pointer after token
  static char* readToken(char *p, char *out, uint8_t outCap) {
    uint8_t k = 0;
    p = skipSpaces(p);
    while (*p && *p != ' ' && k + 1 < outCap) {
      out[k++] = *p++;
    }
    out[k] = '\0';
    return p;
  }

  // -------- command handlers (SERVER SIDE) --------

  static void handleHello(uint8_t ci, char *line) {
    // hello [username] [clientport]
    char tok[12];
    char name[CHAT_NAME_MAX];

    line = skipSpaces(line);
    line = readToken(line, tok, sizeof(tok)); 
    line = readToken(line, name, sizeof(name)); 

    if (name[0] == '\0') return;

    strncpy(clients[ci].name, name, CHAT_NAME_MAX-1);
    clients[ci].name[CHAT_NAME_MAX-1] = '\0';

    {
      char out[CHAT_LINE_MAX];
      str_clear(out, sizeof(out));
      str_cat(out, sizeof(out), clients[ci].name);
      str_cat(out, sizeof(out), " joined\r\n");
      broadcast(out);
    }
  }

  static void handleMsg(uint8_t ci, char *line) {
    // msg [message...]
    // broadcast: "<user>: <message>\r\n"
    char tok[8];
    char out[CHAT_LINE_MAX];

    line = readToken(line, tok, sizeof(tok));
    line = skipSpaces(line); 

    str_clear(out, sizeof(out));
    if (clients[ci].name[0] != '\0') str_cat(out, sizeof(out), clients[ci].name);
    else str_cat(out, sizeof(out), "anon");
    str_cat(out, sizeof(out), ": ");
    str_cat(out, sizeof(out), line);
    str_cat(out, sizeof(out), "\r\n");
    broadcast(out);
  }

  static void handleWhisper(uint8_t ci, char *line) {
    // whisper [username] [message...]
    char tok[10];
    char target[CHAT_NAME_MAX];
    char out[CHAT_LINE_MAX];

    line = readToken(line, tok, sizeof(tok)); 
    line = readToken(line, target, sizeof(target));
    line = skipSpaces(line); 

    {
      int8_t ti = findByName(target);
      if (ti < 0) {
        sendTo(clients[ci].fd, "whisperRply user-not-found\r\n");
        return;
      }

      str_clear(out, sizeof(out));
      str_cat(out, sizeof(out), "whisper ");
      if (clients[ci].name[0] != '\0') str_cat(out, sizeof(out), clients[ci].name);
      else str_cat(out, sizeof(out), "anon");
      str_cat(out, sizeof(out), ": ");
      str_cat(out, sizeof(out), line);
      str_cat(out, sizeof(out), "\r\n");

      sendTo(clients[(uint8_t)ti].fd, out);
    }
  }

  static void handleListUsr(uint8_t ci) {
    // reply: listUsrRply a, b, c\r\n
    char out[CHAT_LINE_MAX];
    uint8_t i;
    uint8_t first = 1;

    str_clear(out, sizeof(out));
    str_cat(out, sizeof(out), "listUsrRply ");

    for (i = 0; i < CHAT_MAX_CLIENTS; i++) {
      if (!clients[i].inUse) continue;
      if (clients[i].name[0] == '\0') continue;

      if (!first) str_cat(out, sizeof(out), ", ");
      first = 0;
      str_cat(out, sizeof(out), clients[i].name);
    }
    str_cat(out, sizeof(out), "\r\n");
    sendTo(clients[ci].fd, out);
  }

  static void handleLine(uint8_t ci, char *line) {
    // line is a null-terminated command (no \r\n)
    char cmd[12];
    char *p = readToken(line, cmd, sizeof(cmd));

    if (strncmp(cmd, "hello", 5) == 0) handleHello(ci, line);
    else if (strncmp(cmd, "msg", 3) == 0) handleMsg(ci, line);
    else if (strncmp(cmd, "whisper", 7) == 0) handleWhisper(ci, line);
    else if (strncmp(cmd, "listusr", 7) == 0) handleListUsr(ci);
    else {
      sendTo(clients[ci].fd, "err unknown-cmd\r\n");
    }
    (void)p;
  }

  // -------- timer-driven accept + read --------

  event void ChatTimer.fired() {
    socket_t newFd;
    uint8_t i;

    if (listenFd == INVALID_FD) return;

    // accept loop
    newFd = call Transport.accept(listenFd);
    while (newFd != INVALID_FD) {
      int8_t slot = findFreeSlot();
      if (slot < 0) {
        dbg(CHAT_CHANNEL, "CHAT: too many clients, closing fd=%u\n", newFd);
        call Transport.close(newFd);
      } else {
        clients[(uint8_t)slot].inUse = 1;
        clients[(uint8_t)slot].fd = newFd;
        clients[(uint8_t)slot].name[0] = '\0';
        clients[(uint8_t)slot].inlen = 0;
        clients[(uint8_t)slot].inbuf[0] = '\0';
        dbg(CHAT_CHANNEL, "CHAT: accepted fd=%u slot=%d\n", newFd, slot);
      }
      newFd = call Transport.accept(listenFd);
    }

    // read loop
    for (i = 0; i < CHAT_MAX_CLIENTS; i++) {
      uint8_t tmp[32];
      uint16_t n;

      if (!clients[i].inUse) continue;

      n = call Transport.read(clients[i].fd, tmp, sizeof(tmp));
      if (n == 0) continue;

      // append to stream buffer
      {
        uint16_t k;
        for (k = 0; k < n; k++) {
          if (clients[i].inlen + 1 >= CHAT_LINE_MAX) {
            // overflow -> drop
            dropClient(i);
            break;
          }
          clients[i].inbuf[clients[i].inlen++] = (char)tmp[k];
          clients[i].inbuf[clients[i].inlen] = '\0';
        }
        if (!clients[i].inUse) continue;
      }

      // process all complete lines
      while (1) {
        int16_t cut = findCRLF(clients[i].inbuf, clients[i].inlen);
        if (cut < 0) break;

        // extract line into local buffer
        {
          char line[CHAT_LINE_MAX];
          uint8_t remain;
          uint8_t j;

          // copy up to cut
          if ((uint8_t)cut >= CHAT_LINE_MAX) { dropClient(i); break; }
          for (j = 0; j < (uint8_t)cut; j++) line[j] = clients[i].inbuf[j];
          line[(uint8_t)cut] = '\0';

          // consume cut+2 from inbuf
          remain = clients[i].inlen - ((uint8_t)cut + 2);
          for (j = 0; j < remain; j++) clients[i].inbuf[j] = clients[i].inbuf[(uint8_t)cut + 2 + j];
          clients[i].inlen = remain;
          clients[i].inbuf[clients[i].inlen] = '\0';

          dbg(CHAT_CHANNEL, "CHAT: line fd=%u: \"%s\"\n", clients[i].fd, line);
          handleLine(i, line);
        }
      }
    }
  }

  // -------- interface --------

  command void ChatServer.start(uint8_t port) {
    socket_addr_t addr;

    resetClients();

    listenFd = call Transport.socket();
    if (listenFd == INVALID_FD) {
      dbg(CHAT_CHANNEL, "CHAT: no socket for listen\n");
      return;
    }

    addr.addr = TOS_NODE_ID;
    addr.port = port;

    if (call Transport.bind(listenFd, &addr) != SUCCESS) {
      dbg(CHAT_CHANNEL, "CHAT: bind failed port=%u\n", port);
      call Transport.release(listenFd);
      listenFd = INVALID_FD;
      return;
    }

    if (call Transport.listen(listenFd) != SUCCESS) {
      dbg(CHAT_CHANNEL, "CHAT: listen failed port=%u\n", port);
      call Transport.release(listenFd);
      listenFd = INVALID_FD;
      return;
    }

    dbg(CHAT_CHANNEL, "CHAT: server listening on %u:%u (fd=%u)\n",
        addr.addr, addr.port, listenFd);

    call ChatTimer.startPeriodic(200);
  }

  command void ChatServer.stop() {
    uint8_t i;

    if (listenFd != INVALID_FD) {
      call Transport.close(listenFd);
      listenFd = INVALID_FD;
    }

    for (i = 0; i < CHAT_MAX_CLIENTS; i++) {
      if (clients[i].inUse) dropClient(i);
    }

    call ChatTimer.stop();
    dbg(CHAT_CHANNEL, "CHAT: server stopped\n");
  }
}
