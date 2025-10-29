# project2Test.py
# Turn-in style test for Link-State routing:
#  - ring_8.topo baseline ping 1->5
#  - route dump from node 1
#  - disable node 3 to break the short path
#  - wait for LS reconvergence
#  - ping 1->5 again (should take the other side of the ring)
#  - post-failover route dump

from TestSim import TestSim

SRC = 1
DST = 5
FAIL_NODE = 3

def cmdRouteDMP(sim, at_node):
    sim.routeDMP(at_node)

def main():
    s = TestSim()

    # Set up radio + noise + boot
    s.runTime(1)
    s.loadTopo("small_ring.topo")
    s.loadNoise("no_noise.txt")
    s.bootAll()

    # Turn on the channels we care about
    s.addChannel(s.COMMAND_CHANNEL)
    s.addChannel(s.GENERAL_CHANNEL)
    s.addChannel(s.FLOODING_CHANNEL)
    s.addChannel(s.NEIGHBOR_CHANNEL)
    s.addChannel(s.ROUTING_CHANNEL)

    # Let ND start and LSAs propagate a bit
    s.runTime(25)

    print("\n=== Phase 1: baseline ping {} -> {} ===".format(SRC, DST))
    s.ping(SRC, DST, "baseline")
    s.runTime(2)  # give time for reply to get back

    print("\n=== Baseline Route Dump (node {} to dest {}) ===".format(SRC, DST))
    # Your Node currently dumps whole table; destination is informational here
    cmdRouteDMP(s, SRC)
    s.runTime(1)

    # ---- Break the path by turning OFF node 3 ----
    print("\n=== Phase 2: disabling node {} to break the path ===".format(FAIL_NODE))
    s.moteOff(FAIL_NODE)
    s.runTime(40)

    print("\n=== Phase 3: failover ping {} -> {} (should find alternate path) ===".format(SRC, DST))
    s.ping(SRC, DST, "after-failure")
    s.runTime(3)

    print("\n=== Post-Failover Route Dump (node {} to dest {}) ===".format(SRC, DST))
    cmdRouteDMP(s, SRC)
    s.runTime(1)
    
    print("\n=== Phase 4: re-enable node {} and ping again ===".format(FAIL_NODE))
    s.moteOn(FAIL_NODE)
    s.runTime(35)
    s.ping(SRC, DST, "after-recovery")
    s.runTime(3)
    print("\n=== Final Route Dump (node {} after recovery) ===".format(SRC))
    cmdRouteDMP(s, SRC)
    s.runTime(1)

if __name__ == "__main__":
    main()
