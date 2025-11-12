from TestSim import TestSim

def main():
    # Get simulation ready to run.
    s = TestSim();

    # Before we do anything, lets simulate the network off.
    s.runTime(1);

    # Load the the layout of the network.
    s.loadTopo("long_line.topo");

    # Add a noise model to all of the motes.
    s.loadNoise("no_noise.txt");

    # Turn on all of the sensors.
    s.bootAll();

    # Add the main channels. These channels are declared in includes/channels.h
    s.addChannel(s.COMMAND_CHANNEL);
    s.addChannel(s.GENERAL_CHANNEL);
    s.addChannel(s.FLOODING_CHANNEL);
    s.addChannel(s.NEIGHBOR_CHANNEL);
    s.addChannel(s.ROUTING_CHANNEL);

    # After sending a ping, simulate a little to prevent collision. Project 1
    #s.runTime(1);
    #s.ping(2, 3, "Hello, World");
    #s.runTime(10);    
    #s.ping(1, 10, "Hi!");
    #s.runTime(20);
    
    # Project 2
    s.runTime(25);
    s.ping(18,4, "Test 1");
    s.runTime(5);

    s.routeDMP(5);
    s.runTime(5);

    s.moteOff(6);
    s.runTime(20);

    s.ping(5,10, "Test 2")
    s.runTime(20);
    s.routeDMP(7);
    s.runTime(5);


if __name__ == '__main__':
    main()
