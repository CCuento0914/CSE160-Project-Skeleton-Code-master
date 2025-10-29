from TestSim import TestSim

def main():
    s = TestSim()

    # Network is off initially
    s.runTime(1)

    # Topology + noise + boot
    s.loadTopo("long_line.topo")
    s.loadNoise("no_noise.txt")
    s.bootAll()

    # Channels
    s.addChannel(s.COMMAND_CHANNEL)
    s.addChannel(s.GENERAL_CHANNEL)
    s.addChannel(s.FLOODING_CHANNEL)
    s.addChannel(s.NEIGHBOR_CHANNEL)
    
    s.neighborDMP(5)  
    s.runTime(20)

    s.ping(3, 19, "Test1")
    s.runTime(10)             

    s.moteOff(5)
    s.runTime(10) 

    s.ping(4, 7, "Test2")
    s.runTime(5)
  
    s.neighborDMP(6) 
    s.runTime(5)

if __name__ == '__main__':
    main()
