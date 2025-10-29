interface LinkState {
  command void noteNeighborChange();
  command int16_t nextHop(uint16_t dest);
  command void handleLSA(pack *p);
  command void routeDump();
}
