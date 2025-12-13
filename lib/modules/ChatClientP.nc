#include <Timer.h>
#include <string.h>
#include "../../includes/socket.h"
#include "../../includes/channels.h"

module ChatClientP {
  provides interface ChatClient;
  uses interface Transport;
  uses interface Timer<TMilli> as ChatClientTimer;
}
implementation {

  enum {
    INVALID_FD = 255,

    ST_DISCONNECTED = 0,
    ST_CONNECTING = 1,
    ST_CONNECTED = 2,
  };

  enum {
    CHAT_SERVER_NODE = 1,
    CHAT_SERVER_PORT = 41,
  };

  static socket_t clientFd = INVALID_FD;
  static uint8_t state = ST_DISCONNECTED;

  static uint8_t myPort = 0;
  static char myName[16]; 
  static char pendingLine[80]; 

  // ---- helpers ----

  static void resetClient() {
    if (clientFd != INVALID_FD) {
      call Transport.close(clientFd);
    }
    clientFd = INVALID_FD;
    state = ST_DISCONNECTED;
    myPort = 0;
    myName[0] = '\0';
    pendingLine[0] = '\0';
    call ChatClientTimer.stop();
  }

  static uint8_t isSpace(char c) { return (c == ' ' || c == '\t'); }

  static void ensureCRLF(char *s, uint16_t maxLen) {
    uint16_t n;
    n = strlen(s);
    if (n >= 2 && s[n-2] == '\r' && s[n-1] == '\n') return;

    // add \r\n if room
    if (n + 2 < maxLen) {
      s[n] = '\r';
      s[n+1] = '\n';
      s[n+2] = '\0';
    }
  }

  static void sendLineNow(const char *line) {
    uint16_t len;
    if (state != ST_CONNECTED || clientFd == INVALID_FD) return;

    len = (uint16_t)strlen(line);
    if (len == 0) return;

    // write exact bytes (do NOT include extra null terminator)
    call Transport.write(clientFd, (uint8_t*)line, len);
  }

  static void tryConnect() {
    socket_addr_t src;
    socket_addr_t dst;
    char helloLine[40];
    uint16_t pos;
    uint16_t i;

    if (state != ST_CONNECTING) return;
    if (clientFd == INVALID_FD) return;

    dst.addr = CHAT_SERVER_NODE;
    dst.port = CHAT_SERVER_PORT;

    if (call Transport.connect(clientFd, &dst) != SUCCESS) {
      dbg(CHAT_CHANNEL, "CHATCLIENT: connect() failed, will retry\n");
      return;
    }

    helloLine[0] = '\0';
    pos = 0;

    // build: "hello " + myName + "\r\n"
    if (pos + 6 < sizeof(helloLine)) {
      helloLine[pos++] = 'h'; helloLine[pos++] = 'e'; helloLine[pos++] = 'l';
      helloLine[pos++] = 'l'; helloLine[pos++] = 'o'; helloLine[pos++] = ' ';
      helloLine[pos] = '\0';
    }

    i = 0;
    while (myName[i] != '\0' && pos + 1 < sizeof(helloLine)) {
      helloLine[pos++] = myName[i++];
      helloLine[pos] = '\0';
    }

    ensureCRLF(helloLine, sizeof(helloLine));

    strncpy(pendingLine, helloLine, sizeof(pendingLine)-1);
    pendingLine[sizeof(pendingLine)-1] = '\0';

    // start polling reads + flushing pending writes
    call ChatClientTimer.startPeriodic(150);
    dbg(CHAT_CHANNEL,
        "CHATCLIENT: connect initiated to %u:%u, queued \"%s\"\n",
        CHAT_SERVER_NODE, CHAT_SERVER_PORT, pendingLine);
  }

  // ---- timer: poll reads + flush pending ----

  event void ChatClientTimer.fired() {
    uint8_t buf[80];
    uint16_t n;

    if (clientFd == INVALID_FD) return;
    if (state == ST_CONNECTING) {
      // Try to flush pending hello; if write is blocked it’ll just be 0.
      if (pendingLine[0] != '\0') {
        uint16_t len;
        uint16_t wrote;

        len = (uint16_t)strlen(pendingLine);
        wrote = call Transport.write(clientFd, (uint8_t*)pendingLine, len);
        if (wrote > 0) {
          dbg(CHAT_CHANNEL, "CHATCLIENT: sent hello (%u bytes)\n", wrote);
          pendingLine[0] = '\0';
          state = ST_CONNECTED;
          dbg(CHAT_CHANNEL, "CHATCLIENT: CONNECTED\n");
        }
      }
    } else if (state == ST_CONNECTED) {
      // flush any queued outbound line
      if (pendingLine[0] != '\0') {
        uint16_t len2;
        uint16_t wrote2;
        len2 = (uint16_t)strlen(pendingLine);
        wrote2 = call Transport.write(clientFd, (uint8_t*)pendingLine, len2);
        if (wrote2 > 0) {
          pendingLine[0] = '\0';
        }
      }
    }

    // read any server output
    n = call Transport.read(clientFd, buf, sizeof(buf)-1);
    if (n > 0) {
      if (n >= sizeof(buf)) n = sizeof(buf)-1;
      buf[n] = '\0';
      dbg(CHAT_CHANNEL, "CHATCLIENT: recv \"%s\"\n", (char*)buf);
    }
  }

  // ---- parse "hello name port\r\n" ----

  static void parseHelloLine(const char *line) {
    const char *p;
    char uname[16];
    uint8_t ui;
    uint16_t portVal;

    uname[0] = '\0';
    ui = 0;
    portVal = 0;

    p = line;

    // skip leading spaces
    while (*p && isSpace(*p)) p++;

    // skip "hello"
    if (p[0]=='h' && p[1]=='e' && p[2]=='l' && p[3]=='l' && p[4]=='o') {
      p += 5;
    }

    while (*p && isSpace(*p)) p++;

    // username token
    while (*p && !isSpace(*p) && *p != '\r' && *p != '\n' && ui < (sizeof(uname)-1)) {
      uname[ui++] = *p++;
    }
    uname[ui] = '\0';

    while (*p && isSpace(*p)) p++;

    // port number
    while (*p >= '0' && *p <= '9') {
      portVal = (uint16_t)(portVal * 10 + (uint16_t)(*p - '0'));
      p++;
    }

    if (uname[0] == '\0' || portVal == 0 || portVal > 255) {
      dbg(CHAT_CHANNEL, "CHATCLIENT: bad hello line: \"%s\"\n", line);
      return;
    }

    strncpy(myName, uname, sizeof(myName)-1);
    myName[sizeof(myName)-1] = '\0';
    myPort = (uint8_t)portVal;
  }

  // ---- ChatClient commands (called from Node via CommandHandler) ----

  command void ChatClient.chatHello(uint8_t* payload) {
    socket_addr_t src;
    char lineCopy[80];

    // payload is a C-string from CommandMsg
    strncpy(lineCopy, (char*)payload, sizeof(lineCopy)-1);
    lineCopy[sizeof(lineCopy)-1] = '\0';

    dbg(CHAT_CHANNEL, "CHATCLIENT CMD: %s\n", lineCopy);

    // reset any old connection
    resetClient();

    parseHelloLine(lineCopy);
    if (myPort == 0 || myName[0] == '\0') return;

    // create socket + bind to client port
    clientFd = call Transport.socket();
    if (clientFd == INVALID_FD) {
      dbg(CHAT_CHANNEL, "CHATCLIENT: no free socket\n");
      resetClient();
      return;
    }

    src.addr = TOS_NODE_ID;
    src.port = myPort;

    if (call Transport.bind(clientFd, &src) != SUCCESS) {
      dbg(CHAT_CHANNEL, "CHATCLIENT: bind failed on %u:%u\n", src.addr, src.port);
      resetClient();
      return;
    }

    state = ST_CONNECTING;

    // start a short periodic timer to (a) retry connect, (b) flush hello when ready, (c) read
    call ChatClientTimer.startPeriodic(150);
    tryConnect();
  }

  command void ChatClient.chatMsg(uint8_t* payload) {
    char line[80];

    strncpy(line, (char*)payload, sizeof(line)-1);
    line[sizeof(line)-1] = '\0';
    ensureCRLF(line, sizeof(line));

    if (state != ST_CONNECTED) {
      // queue last command (simple)
      strncpy(pendingLine, line, sizeof(pendingLine)-1);
      pendingLine[sizeof(pendingLine)-1] = '\0';
      return;
    }

    sendLineNow(line);
  }

  command void ChatClient.chatWhisper(uint8_t* payload) {
    char line[80];

    strncpy(line, (char*)payload, sizeof(line)-1);
    line[sizeof(line)-1] = '\0';
    ensureCRLF(line, sizeof(line));

    if (state != ST_CONNECTED) {
      strncpy(pendingLine, line, sizeof(pendingLine)-1);
      pendingLine[sizeof(pendingLine)-1] = '\0';
      return;
    }

    sendLineNow(line);
  }

  command void ChatClient.chatListUsr() {
    char line[16];
    strncpy(line, "listusr\r\n", sizeof(line));
    line[sizeof(line)-1] = '\0';

    if (state != ST_CONNECTED) {
      strncpy(pendingLine, line, sizeof(pendingLine)-1);
      pendingLine[sizeof(pendingLine)-1] = '\0';
      return;
    }

    sendLineNow(line);
  }
}
