interface Flooding(){
    command void flood(pack* p);
    event void floodReceived(pack* p, uint16_t src);
}