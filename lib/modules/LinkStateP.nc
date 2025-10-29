#include <Timer.h>
#include "../../includes/packet.h"
#include "../../includes/channels.h"
#include "../../includes/protocol.h"
#include <string.h>

module LinkStateP {
  provides interface LinkState;
  uses interface Timer<TMilli> as lsTimer;
  uses interface NeighborDiscover as NeighborDiscover;
  uses interface Flooding;
}
implementation {
  #define MAX_NODES 64
  #define MAX_NEI 16
  #define INF 0x3FFF
  #define LSA_TTL 30
  #define LSA_DEBOUNCE 5000
  #define LSA_PERIOD_MS 150000

  typedef struct {
    uint16_t origin;
    uint16_t seq;
    uint8_t ncount;
    uint16_t neigh[MAX_NEI];
  } __attribute__ ((packed)) lsa_payload_t;

  typedef struct {
    bool used;
    uint16_t seq;
    uint8_t  ncount;
    uint16_t neigh[MAX_NEI];
  } lsdb_entry_t;

  static lsdb_entry_t lsdb[MAX_NODES+1];
  static int16_t nextHopTbl[MAX_NODES+1];
  static uint16_t mySeq;

  static bool debounceArmed = FALSE; 
  static bool hbStarted = FALSE;

  static inline bool in_list(uint16_t *a, uint8_t n, uint16_t x) {
    uint8_t i; for (i=0;i<n;i++) if (a[i]==x) return TRUE; return FALSE;
  }
  static inline bool bidir(uint16_t a, uint16_t b) {
    if (!lsdb[a].used || !lsdb[b].used) return FALSE;
    if (!in_list(lsdb[a].neigh, lsdb[a].ncount, b)) return FALSE;
    if (!in_list(lsdb[b].neigh, lsdb[b].ncount, a)) return FALSE;
    return TRUE;
  }

  static void recompute() { // Dijkstra
    int  dist[MAX_NODES+1], prev[MAX_NODES+1];
    bool vis [MAX_NODES+1];
    int  i,j,u,best;

    for (i=0;i<=MAX_NODES;i++){ nextHopTbl[i]=-1; dist[i]=INF; prev[i]=-1; vis[i]=FALSE; }
    dist[TOS_NODE_ID]=0;

    for (i=0;i<MAX_NODES;i++){
      u=-1; best=INF;
      for (j=1;j<=MAX_NODES;j++) if(!vis[j] && dist[j]<best){best=dist[j];u=j;}
      if(u==-1)break;
      vis[u]=TRUE;
      if(!lsdb[u].used)continue;
      for(j=0;j<lsdb[u].ncount;j++){
        uint16_t v=lsdb[u].neigh[j];
        if(!bidir(u,v))continue;
        if(dist[u]+1<dist[v]){ dist[v]=dist[u]+1; prev[v]=u; }
      }
    }
    for (i=1;i<=MAX_NODES;i++){
      if(i==TOS_NODE_ID || dist[i]==INF) continue;
      { int cur=i, pre=prev[i], hop=i;
        while(pre!=-1 && pre!=TOS_NODE_ID){ hop=pre; pre=prev[pre]; }
        if(pre==TOS_NODE_ID) nextHopTbl[i]=hop;
      }
    }
  }

  static void send_lsa_now() {
    pack p; lsa_payload_t *lp; uint16_t buf[MAX_NEI]; uint8_t n;
    memset(&p,0,sizeof(pack));
    p.src=TOS_NODE_ID; p.dest=AM_BROADCAST_ADDR;
    p.TTL=LSA_TTL; p.seq=++mySeq; p.protocol=PROTOCOL_LINKSTATE;

    lp=(lsa_payload_t*)p.payload;
    lp->origin=TOS_NODE_ID; lp->seq=mySeq;
    n = call NeighborDiscover.snapshot(buf, MAX_NEI);
    if(n>MAX_NEI) n=MAX_NEI;
    lp->ncount=n; if(n>0) memcpy(lp->neigh, buf, sizeof(uint16_t)*n);

    call Flooding.handleReceive(&p);
    //dbg(ROUTING_CHANNEL,"LS: sent LSA seq=%u n=%u\n", lp->seq, lp->ncount);
  }

  command void LinkState.noteNeighborChange() {
    if (!debounceArmed) {
      debounceArmed = TRUE;
      call lsTimer.startOneShot(LSA_DEBOUNCE);
    }
  }

  command int16_t LinkState.nextHop(uint16_t dest) {
    if (dest<=MAX_NODES) return nextHopTbl[dest];
    return -1;
  }

  command void LinkState.routeDump() {
    int i,j;
    dbg(ROUTING_CHANNEL,"LS DUMP @%u\n", TOS_NODE_ID);
    for(i=1;i<=MAX_NODES;i++) if(lsdb[i].used){
      dbg_clear(ROUTING_CHANNEL,"  LSA %u seq=%u:", i, lsdb[i].seq);
      for(j=0;j<lsdb[i].ncount;j++) dbg_clear(ROUTING_CHANNEL," %u", lsdb[i].neigh[j]);
      dbg(ROUTING_CHANNEL,"\n");
    }
    for(i=1;i<=MAX_NODES;i++) if(i!=TOS_NODE_ID && nextHopTbl[i]>=0)
      dbg(ROUTING_CHANNEL,"  route to %u via %u\n", i, nextHopTbl[i]);
  }

  command void LinkState.handleLSA(pack *p) {
    lsa_payload_t *lp=(lsa_payload_t*)p->payload;
    uint16_t u = lp->origin;
    uint8_t  k;
    if(u==0 || u>MAX_NODES) return;
    if(lsdb[u].used && lp->seq <= lsdb[u].seq) return; 
    k = lp->ncount; if(k>MAX_NEI) k=MAX_NEI;
    lsdb[u].used=TRUE; lsdb[u].seq=lp->seq; lsdb[u].ncount=k;
    if(k>0) memcpy(lsdb[u].neigh, lp->neigh, sizeof(uint16_t)*k);
    recompute();
  }

  event void lsTimer.fired() {
    if (debounceArmed) {
      debounceArmed = FALSE;
      send_lsa_now();

      if (!hbStarted) {
        hbStarted = TRUE;
        call lsTimer.startPeriodic(LSA_PERIOD_MS);
      }
      return;
    }

    if (hbStarted) {
      send_lsa_now();
    }
  }
}
