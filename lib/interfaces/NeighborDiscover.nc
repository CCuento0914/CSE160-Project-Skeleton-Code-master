interface NeighborDiscover{
    command void findNeighbors();
    command void printNeighbors();
    command void Receive(uint16_t src);
    command uint8_t snapshot(uint16_t *out, uint8_t maxn);
}