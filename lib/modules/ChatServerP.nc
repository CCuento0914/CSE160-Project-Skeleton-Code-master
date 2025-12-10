// lib/modules/ChatServerP.nc
#include <Timer.h>
#include <string.h>
#include <stdint.h>
#include "../../includes/socket.h"
#include "../../includes/channels.h"

module ChatServerP {
  provides interface ChatServer;
  uses interface Transport;
  uses interface Timer<TMilli> as ChatTimer;
}
implementation {

  // ---- constants ----
  enum {
    CHAT_MAX_CLIENTS = 8,
    CHAT_NAME_MAX = 16,
    CHAT_MSG_MAX = 64,
    INVALID_FD = 255
  };

  typedef struct {
    uint8_t inUse; 
    socket_t fd;
    char name[CHAT_NAME_MAX]; 
  } chat_client_t;

  static socket_t listenFd = INVALID_FD;
  static uint8_t listenPort = 0;
  static chat_client_t clients[CHAT_MAX_CLIENTS];

  // ---- helpers ----

  static void resetClients() {
    uint8_t i;
    for (i = 0; i < CHAT_MAX_CLIENTS; i++) {
      clients[i].inUse = 0;
      clients[i].fd    = INVALID_FD;
      clients[i].name[0] = '\0';
    }
  }

  static int8_t findFreeClientSlot() {
    uint8_t i;
    for (i = 0; i < CHAT_MAX_CLIENTS; i++) {
      if (!clients[i].inUse) return (int8_t)i;
    }
    return -1;
  }

  static int8_t findClientByName(const char *name) {
    uint8_t i;
    for (i = 0; i < CHAT_MAX_CLIENTS; i++) {
      if (clients[i].inUse &&
          (strncmp(clients[i].name, name, CHAT_NAME_MAX) == 0)) {
        return (int8_t)i;
      }
    }
    return -1;
  }

  static void sendToOne(socket_t fd, const char *msg) {
    uint16_t len = strlen(msg);
    if (len >= CHAT_MSG_MAX) {
      len = CHAT_MSG_MAX - 1;
    }
    // send as bytes (no implicit '\0' required on the wire)
    (void)call Transport.write(fd, (uint8_t*)msg, len);
  }

  static void broadcastToAll(const char *msg) {
    uint8_t i;
    uint16_t len = strlen(msg);
    if (len >= CHAT_MSG_MAX) {
      len = CHAT_MSG_MAX - 1;
    }

    for (i = 0; i < CHAT_MAX_CLIENTS; i++) {
      if (clients[i].inUse) {
        uint16_t w = call Transport.write(clients[i].fd, (uint8_t*)msg, len);
        dbg(TRANSPORT_CHANNEL,
            "CHAT: broadcast to fd=%u (%s), wrote=%u\n",
            clients[i].fd, clients[i].name, w);
      }
    }
  }

  static void trimNewline(char *s) {
    int16_t len = (int16_t)strlen(s);
    while (len > 0 &&
           (s[len-1] == '\n' || s[len-1] == '\r')) {
      s[len-1] = '\0';
      len--;
    }
  }

  static void handleClientInput(uint8_t ci, char *buf) {
    // buf is null-terminated text from one TCP read
    trimNewline(buf);

    dbg(TRANSPORT_CHANNEL,
        "CHAT: parse from client[%u] (%s): \"%s\"\n",
        ci,
        (clients[ci].name[0] ? clients[ci].name : "<noname>"),
        buf);

    // 1) hello [username]
    if (!strncmp(buf, "hello ", 6)) {
      char *name = buf + 6;
      // skip leading spaces
      while (*name == ' ') name++;
      strncpy(clients[ci].name, name, CHAT_NAME_MAX - 1);
      clients[ci].name[CHAT_NAME_MAX - 1] = '\0';

      // announce join
      {
        char out[CHAT_MSG_MAX];
        uint8_t pos = 0;
        const char *pfx = "JOIN: ";
        const char *name2 = clients[ci].name;
        uint8_t k;

        for (k = 0; pfx[k] != '\0' && pos < CHAT_MSG_MAX - 1; k++) {
          out[pos++] = pfx[k];
        }
        for (k = 0; name2[k] != '\0' && pos < CHAT_MSG_MAX - 1; k++) {
          out[pos++] = name2[k];
        }
        out[pos] = '\0';

        broadcastToAll(out);
      }
      return;
    }

    // 2) msg [message...]
    if (!strncmp(buf, "msg ", 4)) {
      char *msg = buf + 4;
      while (*msg == ' ') msg++;

      {
        char out[CHAT_MSG_MAX];
        uint8_t pos = 0;
        const char *name =
          (clients[ci].name[0] ? clients[ci].name : "anon");
        uint8_t k;

        // "<name>: <msg>"
        for (k = 0; name[k] != '\0' && pos < CHAT_MSG_MAX - 1; k++) {
          out[pos++] = name[k];
        }
        if (pos < CHAT_MSG_MAX - 2) {
          out[pos++] = ':';
          out[pos++] = ' ';
        }
        k = 0;
        while (msg[k] != '\0' && pos < CHAT_MSG_MAX - 1) {
          out[pos++] = msg[k++];
        }
        out[pos] = '\0';

        broadcastToAll(out);
      }
      return;
    }

    // 3) whisper [username] [message...]
    if (!strncmp(buf, "whisper ", 8)) {
      char *p = buf + 8;
      char target[CHAT_NAME_MAX];
      char message[CHAT_MSG_MAX];
      uint8_t ti = 0, mi = 0;

      // skip spaces
      while (*p == ' ') p++;

      // target
      while (*p && *p != ' ' && ti < CHAT_NAME_MAX - 1) {
        target[ti++] = *p++;
      }
      target[ti] = '\0';

      // skip spaces between target and message
      while (*p == ' ') p++;

      // rest is message
      while (*p && mi < CHAT_MSG_MAX - 1) {
        message[mi++] = *p++;
      }
      message[mi] = '\0';

      {
        int8_t idx = findClientByName(target);
        if (idx >= 0) {
          char out[CHAT_MSG_MAX];
          uint8_t pos = 0;
          const char *from =
            (clients[ci].name[0] ? clients[ci].name : "anon");
          uint8_t k;

          // "whisper from <from>: <message>"
          const char *pfx = "whisper from ";
          for (k = 0; pfx[k] != '\0' && pos < CHAT_MSG_MAX - 1; k++) {
            out[pos++] = pfx[k];
          }
          for (k = 0; from[k] != '\0' && pos < CHAT_MSG_MAX - 1; k++) {
            out[pos++] = from[k];
          }
          if (pos < CHAT_MSG_MAX - 2) {
            out[pos++] = ':';
            out[pos++] = ' ';
          }
          k = 0;
          while (message[k] != '\0' && pos < CHAT_MSG_MAX - 1) {
            out[pos++] = message[k++];
          }
          out[pos] = '\0';

          sendToOne(clients[idx].fd, out);
        } else {
          sendToOne(clients[ci].fd, "user not found");
        }
      }
      return;
    }

    // 4) listusr
    if (!strcmp(buf, "listusr") || !strncmp(buf, "listusr ", 8)) {
      char out[CHAT_MSG_MAX];
      uint8_t pos = 0;
      uint8_t j;

      for (j = 0; j < CHAT_MAX_CLIENTS; j++) {
        if (!clients[j].inUse || clients[j].name[0] == '\0') continue;

        if (pos > 0 && pos < CHAT_MSG_MAX - 2) {
          out[pos++] = ',';
          out[pos++] = ' ';
        }

        {
          uint8_t k = 0;
          while (clients[j].name[k] != '\0' && pos < CHAT_MSG_MAX - 1) {
            out[pos++] = clients[j].name[k++];
          }
        }
      }

      if (pos == 0) {
        const char *msg = "no users";
        uint8_t k = 0;
        while (msg[k] != '\0' && pos < CHAT_MSG_MAX - 1) {
          out[pos++] = msg[k++];
        }
      }
      out[pos] = '\0';

      sendToOne(clients[ci].fd, out);
      return;
    }

    dbg(TRANSPORT_CHANNEL,
        "CHAT: unknown command from client[%u]: \"%s\"\n", ci, buf);
  }

  // ---- Timer: accept connections + read data ----

  event void ChatTimer.fired() {
    socket_t newFd;
    uint8_t i;

    if (listenFd == INVALID_FD) {
      return;
    }

    // Accept as many pending connections as possible
    newFd = call Transport.accept(listenFd);
    while (newFd != INVALID_FD) {
      int8_t slot = findFreeClientSlot();
      if (slot < 0) {
        dbg(TRANSPORT_CHANNEL,
            "CHAT: too many clients, closing fd=%u\n", newFd);
        call Transport.close(newFd);
      } else {
        clients[slot].inUse = 1;
        clients[slot].fd    = newFd;
        clients[slot].name[0] = '\0';
        dbg(TRANSPORT_CHANNEL,
            "CHAT: accepted new client fd=%u (slot=%d)\n", newFd, slot);
      }
      newFd = call Transport.accept(listenFd);
    }

    // Read from each active client
    for (i = 0; i < CHAT_MAX_CLIENTS; i++) {
      uint8_t buf[CHAT_MSG_MAX];
      uint16_t n;

      if (!clients[i].inUse || clients[i].fd == INVALID_FD) {
        continue;
      }

      n = call Transport.read(clients[i].fd, buf, sizeof(buf) - 1);
      if (n == 0) {
        continue;
      }

      // ensure null-termination
      if (n >= sizeof(buf)) {
        n = sizeof(buf) - 1;
      }
      buf[n] = '\0';

      dbg(TRANSPORT_CHANNEL,
          "CHAT: received %u bytes from fd=%u\n",
          n, clients[i].fd);

      handleClientInput(i, (char*)buf);
    }
  }

  // ---- ChatServer interface: start/stop + command injection ----

  command void ChatServer.start(uint8_t port) {
    socket_addr_t addr;

    if (listenFd != INVALID_FD) {
      call ChatServer.stop();
    }

    listenPort = port;
    resetClients();

    listenFd = call Transport.socket();
    if (listenFd == INVALID_FD) {
      dbg(TRANSPORT_CHANNEL, "CHAT: no socket for server\n");
      return;
    }

    addr.addr = TOS_NODE_ID;
    addr.port = listenPort;

    if (call Transport.bind(listenFd, &addr) != SUCCESS) {
      dbg(TRANSPORT_CHANNEL,
          "CHAT: bind failed on %u:%u\n", addr.addr, addr.port);
      call Transport.release(listenFd);
      listenFd = INVALID_FD;
      return;
    }

    if (call Transport.listen(listenFd) != SUCCESS) {
      dbg(TRANSPORT_CHANNEL,
          "CHAT: listen failed on port %u\n", listenPort);
      call Transport.release(listenFd);
      listenFd = INVALID_FD;
      return;
    }

    dbg(TRANSPORT_CHANNEL,
        "CHAT: server listening on %u:%u (fd=%u)\n",
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
      if (clients[i].inUse && clients[i].fd != INVALID_FD) {
        call Transport.close(clients[i].fd);
      }
    }
    resetClients();
    call ChatTimer.stop();

    dbg(TRANSPORT_CHANNEL, "CHAT: server stopped\n");
  }

  command void ChatServer.chatHello(uint8_t *payload) {
    // Payload is username
    char out[CHAT_MSG_MAX];
    uint8_t pos = 0;
    const char *pfx = "JOIN (cmd): ";
    uint8_t k = 0;

    while (pfx[k] != '\0' && pos < CHAT_MSG_MAX - 1) {
      out[pos++] = pfx[k++];
    }
    k = 0;
    while (payload[k] != '\0' && pos < CHAT_MSG_MAX - 1) {
      out[pos++] = (char)payload[k++];
    }
    out[pos] = '\0';

    broadcastToAll(out);
  }

  command void ChatServer.chatMsg(uint8_t *payload) {
    // Just broadcast payload as a server message
    char out[CHAT_MSG_MAX];
    uint8_t pos = 0;
    const char *pfx = "SERVER: ";
    uint8_t k = 0;

    while (pfx[k] != '\0' && pos < CHAT_MSG_MAX - 1) {
      out[pos++] = pfx[k++];
    }
    k = 0;
    while (payload[k] != '\0' && pos < CHAT_MSG_MAX - 1) {
      out[pos++] = (char)payload[k++];
    }
    out[pos] = '\0';

    broadcastToAll(out);
  }

  command void ChatServer.chatWhisper(uint8_t *payload) {
    // payload: "targetName message..."
    char *p = (char*)payload;
    char target[CHAT_NAME_MAX];
    char message[CHAT_MSG_MAX];
    uint8_t ti = 0, mi = 0;

    while (*p == ' ') p++;
    while (*p && *p != ' ' && ti < CHAT_NAME_MAX - 1) {
      target[ti++] = *p++;
    }
    target[ti] = '\0';

    while (*p == ' ') p++;
    while (*p && mi < CHAT_MSG_MAX - 1) {
      message[mi++] = *p++;
    }
    message[mi] = '\0';

    {
      int8_t idx = findClientByName(target);
      if (idx >= 0) {
        sendToOne(clients[idx].fd, message);
      }
    }
  }

  command void ChatServer.chatListUsr() {
    // Broadcast the list of users
    char out[CHAT_MSG_MAX];
    uint8_t pos = 0;
    uint8_t j;

    for (j = 0; j < CHAT_MAX_CLIENTS; j++) {
      if (!clients[j].inUse || clients[j].name[0] == '\0') continue;

      if (pos > 0 && pos < CHAT_MSG_MAX - 2) {
        out[pos++] = ',';
        out[pos++] = ' ';
      }
      {
        uint8_t k = 0;
        while (clients[j].name[k] != '\0' && pos < CHAT_MSG_MAX - 1) {
          out[pos++] = clients[j].name[k++];
        }
      }
    }

    if (pos == 0) {
      const char *msg = "no users";
      uint8_t k = 0;
      while (msg[k] != '\0' && pos < CHAT_MSG_MAX - 1) {
        out[pos++] = msg[k++];
      }
    }
    out[pos] = '\0';

    broadcastToAll(out);
  }

}
