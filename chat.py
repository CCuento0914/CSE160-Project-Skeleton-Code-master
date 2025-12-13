from TestSim import TestSim

def main():
    s = TestSim()

    # network off briefly
    s.runTime(1)

    # pick your topo/noise
    s.loadTopo("tuna-melt.topo")
    s.loadNoise("no_noise.txt")
    s.bootAll()

    # channels
    s.addChannel(s.COMMAND_CHANNEL)
    s.addChannel(s.GENERAL_CHANNEL)
    s.addChannel(s.CHAT_CHANNEL)

    # let routing stabilize a bit
    s.runTime(300)

    # 1) start server on node 1 port 41
    s.chatStartServer(serverNode=1)

    s.runTime(200)

    # 2) have two clients "hello" to connect
    s.chatHello(clientNode=4, username="doe", clientPort=50)
    s.runTime(200)

    s.chatHello(clientNode=13, username="john", clientPort=51)
    s.runTime(400)

    # 3) broadcast message from alice
    s.chatMsg(clientNode=4, message="Hello World!")
    s.runTime(300)

    # 4) whisper from bob to alice (keep short!)
    s.chatWhisper(clientNode=13, target="doe", message="whisper")
    s.runTime(300)

    # 5) list users
    s.chatListUsr(clientNode=4)
    s.runTime(1000)

if __name__ == "__main__":
    main()
