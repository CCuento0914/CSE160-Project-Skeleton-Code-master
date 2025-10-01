#include "../../includes/packet.h"

interface Flooding{
    command void FloodTest();
    command void handleReceive(pack *msg);
}