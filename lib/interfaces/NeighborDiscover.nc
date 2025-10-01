interface NeighborDiscover{
    command void findNeighbors();
    command void printNeighbors();
    command void Receive(uint16_t src);
}