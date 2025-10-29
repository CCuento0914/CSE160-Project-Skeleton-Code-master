configuration LinkStateC {
  provides interface LinkState;
  uses interface NeighborDiscover; 
  uses interface Flooding; 
}
implementation {
  components LinkStateP;
  LinkState = LinkStateP;

  components new TimerMilliC() as LSTimer;
  LinkStateP.lsTimer -> LSTimer;

  LinkStateP.NeighborDiscover = NeighborDiscover;
  LinkStateP.Flooding = Flooding;
}
