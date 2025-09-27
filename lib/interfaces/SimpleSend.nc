#include "../../includes/packet.h"

interface SimpleSend{
   command error_t send(am_addr_t dst, uint8_t *payload, uint8_t len);
}
