generic configuration NeighborDiscoverC(am_id_t AMID) {
  provides interface NeighborDiscover;
}
implementation {
  components NeighborDiscoverP;
  NeighborDiscover = NeighborDiscoverP;

  components new TimerMilliC() as T;
  NeighborDiscoverP.neighborTimer -> T;

  components new SimpleSendC(AMID) as SSC;
  NeighborDiscoverP.Sender -> SSC;
}
